# ==== 0) Packages ====
library(haven)     # read_sas
library(dplyr)
library(stringr)
library(mice)
library(MatchIt)
library(cobalt)    # balance diagnostics
library(survival)
library(broom)
library(future)
library(progressr)
library(future.apply)
library(MatchIt)
library(survival)
library(broom)
library(cobalt)

set.seed(2025)

# ==== 1) Read & minimal type hygiene ====
dat <- read_sas("~/Documents/final_pub.sas7bdat")

# Outcome: ensure event=1 for death; time in months from surgery
dat <- dat %>%
  dplyr::mutate(
    # If you still have OS_censor (1 for death in your SAS), convert safely:
    event = case_when(
      !is.na(OS_censor)               ~ as.integer(OS_censor == 1L),          # your earlier SAS created this inverted
      !is.na(PUF_VITAL_STATUS)        ~ as.integer(PUF_VITAL_STATUS == "0"),  # fallback from PUF
      TRUE ~ NA_integer_
    ),
    time  = as.numeric(os_surg),
    # Treatment
    treat = factor(RECON, levels = c("0","1"), labels = c("Mastectomy only","Reconstruction")),
    
    # Patient/context factors
    AGE_num  = suppressWarnings(as.numeric(AGE)),
    year_fac = factor(as.character(YEAR_OF_DIAGNOSIS)),
    race4    = factor(FINAL_RACE, levels = c("01","02","03","04"),
                      labels = c("NH White","NH Black","Hispanic","Asian/PI")),
    insure   = factor(INSURE, levels = c("0","1","2"),
                      labels = c("Uninsured","Government","Private")),
    cdcc_o   = factor(CDCC_TOTAL_BEST, ordered = TRUE, levels = c("0","1","2","3")),
    inc_q    = factor(INC_QUAR_STD, ordered = TRUE, levels = c("1","2","3","4")),
    edu_q    = factor(EDU_QUAR_STD, ordered = TRUE, levels = c("1","2","3","4")),
    UR3      = factor(UR3, levels = c("M","U","R")),
    medexp   = factor(medexp, levels = c("0","1","2","3","U"),
                      labels = c("Non-exp","Jan2014","Early10-13","Late>2014","Unknown")),
    fac_type = factor(FACILITY_TYPE_CD, levels = c("1","2","3","4"),
                      labels = c("Community","Comprehensive","Academic","Integrated")),
    fac_div  = factor(FACILITY_LOCATION_CD, levels = as.character(1:9),
                      labels = c("NE","MidAtl","SouthAtl","ENC","ESC","WNC","WSC","Mountain","Pacific")),
    log_dist = ifelse(is.na(log_dist),
                      log(1 + as.numeric(CROWFLY)),  # fallback if you didn't persist log_dist
                      as.numeric(log_dist)),
    
    # Tumor components / biology (as built in SAS)
    size_mm  = as.numeric(size_mm),
    nodes_pos= as.numeric(nodes_pos),
    nodes_exam=as.numeric(nodes_exam),
    grade_o  = factor(grade_o, ordered = TRUE, levels = c("1","2","3","4")),
    lvi_b    = factor(lvi_b, levels = c("0","1")),        # keep as factor (binary)
    ER_bi    = factor(ER_bi, levels = c("0","1")),
    PR_bi    = factor(PR_bi, levels = c("0","1")),
    HER2_bi  = factor(HER2_bi, levels = c("0","1")),
    
    # Neoadjuvant indicators from sequences (built in SAS; if not, build here similarly)
    NEO_SYS  = as.logical(NEO_SYS),
    NEO_RT   = as.logical(NEO_RT)
  )

# Drop rows without time or event
dat <- dat %>% filter(!is.na(time), time >= 0, !is.na(event), !is.na(treat))

# ==== 2) Specify covariates for PS (component-based) ====
ps_covars <- c(
  # patient & access
  "AGE_num","year_fac","race4","insure","cdcc_o",
  "inc_q","edu_q","UR3","medexp","log_dist",
  # facility
  "fac_type","fac_div",
  # tumor components & biology
  "size_mm","nodes_pos","nodes_exam","grade_o","ER_bi","PR_bi","HER2_bi",
  # neoadjuvant (pre-surgery)
  "NEO_SYS","NEO_RT"
)

# ==== 3) Multiple Imputation for covariates (not treat/outcome/time) ====
mi_dat <- dat %>%
  select(all_of(c("treat","event","time", ps_covars)))

# Methods per type
meth <- make.method(mi_dat)
# Continuous
meth[c("size_mm","nodes_pos","nodes_exam","AGE_num","log_dist")] <- "pmm"
# Ordered factors
meth[c("grade_o","inc_q","edu_q","cdcc_o")] <- "polr"
# Nominal (unordered)
meth[c("race4","insure","fac_type","fac_div","UR3","year_fac","medexp")] <- "polyreg"
# Binary factors
meth[c("ER_bi","PR_bi","HER2_bi")] <- "logreg"
# Logical neoadjuvant → treat as binary
meth[c("NEO_SYS","NEO_RT")] <- "logreg"
# Do NOT impute these:
meth[c("treat","event","time")] <- ""

# Predictor matrix (exclude treat/event/time as targets but allow as predictors)
pred <- quickpred(mi_dat, mincor = 0.05)
pred[ , c("treat","event","time")] <- 1
pred[c("treat","event","time"), ] <- 0


# 0) be nice to your Mac’s math library (avoid oversubscription)
Sys.setenv(VECLIB_MAXIMUM_THREADS = "1")   # macOS Accelerate
# If you use OpenBLAS instead: RhpcBLASctl::blas_set_num_threads(1)

## Tell future how many cores to use
plan(multisession, workers = 10)   # your 10-core choice

## Run parallel MICE
imp <- futuremice(
  mi_dat,
  m = 30, maxit = 20,
  method = meth, predictorMatrix = pred,
  seed = 2025,                  # use 'seed' here
  printFlag = FALSE             # parallel workers don’t stream logs
)

saveRDS(imp, "imp_m30_maxit20.rds")          # portable across OS/CPUs
# (optional, smaller/faster) qs::qsave(imp, "imp_m30_maxit20.qs")

library(future.apply)
library(progressr)

plan(multisession, workers = 10)            # how many cores you want
handlers(global = TRUE); handlers("txtprogressbar")

with_progress({
  p <- progressor(steps = 30)               # total steps
  imp_list <- future_lapply(1:30, function(i) {
    # run one imputation
    imp_i <- mice(mi_dat, m = 1, maxit = 20,
                  method = meth, predictorMatrix = pred,
                  printFlag = FALSE, seed = 2025 + i)
    p(message = sprintf("imputation %d/30", i))  # <-- tick HERE
    imp_i
  }, future.seed = TRUE)
})

imp1 <- Reduce(mice::ibind, imp_list)        # combine 30 mids -> one mids

# okay so first i must impute the missing values
# Then in must do the propensity score match

# How do i know which values I'm going to impute?

# --- parallel setup (use 10 cores, keep UI responsive) ---
plan(multisession, workers = 10)
options(future.wait.interval = 0.1)  # snappier progress polling

# --- pre-complete imputations to avoid shipping 'imp' to every worker ---
datlist <- lapply(seq_len(imp$m), function(i) mice::complete(imp, i))

library(splines)  # for ns()

do_one <- function(dd, caliper = 0.20) {
  # ensure types
  dd <- dd |>
    dplyr::mutate(
      treat = factor(treat, levels = c("Mastectomy only","Reconstruction")),
      event = as.integer(event),
      time  = as.numeric(time)
    )
  
  psf <- treat ~ splines::ns(AGE_num, 4) + year_fac + race4 + insure + cdcc_o +
    inc_q + edu_q + UR3 + medexp + log_dist +
    fac_type + fac_div +
    size_mm + nodes_pos + nodes_exam + grade_o +
    ER_bi + PR_bi + HER2_bi +
    NEO_SYS + NEO_RT
  
  # PS matching (ATT + overlap trimming). If too few pairs, widen caliper once.
  m <- try(
    MatchIt::matchit(psf, data = dd,
                     method   = "nearest",
                     distance = "logit",
                     estimand = "ATT",
                     discard  = "both",
                     caliper  = caliper,
                     ratio    = 1, replace = FALSE),
    silent = TRUE
  )
  if (inherits(m, "try-error") || is.null(m$match.matrix) || sum(!is.na(m$match.matrix)) == 0) {
    m <- MatchIt::matchit(psf, data = dd,
                          method   = "nearest",
                          distance = "logit",
                          estimand = "ATT",
                          discard  = "both",
                          caliper  = 0.25,
                          ratio    = 1, replace = FALSE)
  }
  
  md <- MatchIt::match.data(m)
  if (nrow(md) < 50) return(list(beta = NA_real_, se = NA_real_, smd = NA_real_, n = nrow(md)))
  
  # Balance diagnostics (no printing; new cobalt wants disp = NULL)
  bt <- cobalt::bal.tab(m, un = FALSE, disp = NULL)
  bal_df <- as.data.frame(bt$Balance)
  # Grab an adjusted mean-diff column robustly across cobalt versions
  smd_col <- grep("(Std\\.)?Diff.*Adj|Diff\\.Adj", names(bal_df), value = TRUE)
  smd_max <- if (length(smd_col)) max(abs(bal_df[[smd_col[1]]]), na.rm = TRUE) else NA_real_
  
  # Cox on matched sets; robust SE clustered by matched subclass
  fit <- survival::coxph(survival::Surv(time, event) ~ treat,
                         data = md, robust = TRUE, cluster = subclass)
  est <- broom::tidy(fit)
  list(
    beta = est$estimate[est$term == "treatReconstruction"],  # log(HR)
    se   = est$std.error[est$term == "treatReconstruction"],
    smd  = smd_max,
    n    = nrow(md)
  )
}

# --- run across imputations in parallel, reproducibly ---
res_list <- future_lapply(datlist, do_one, future.seed = TRUE)
plan(sequential)

# pool results (drop any failed imputations gracefully)
keep <- sapply(res_list, function(x) is.finite(x$beta) && is.finite(x$se))
betas <- sapply(res_list[keep], `[[`, "beta")
ses   <- sapply(res_list[keep], `[[`, "se")
pooled <- mice::pool.scalar(Q = betas, U = ses^2, k = length(betas))

HR <- exp(pooled$qbar)
seTot <- sqrt(pooled$t)
CI <- exp(c(pooled$qbar - qt(0.975, df = pooled$df)*seTot,
            pooled$qbar + qt(0.975, df = pooled$df)*seTot))

cat(sprintf("ATT HR = %.3f (95%% CI %.3f–%.3f), p = %.4g\n", HR, CI[1], CI[2], pooled$pvalue))

# optional: quick balance summary across imputations
smds <- sapply(res_list[keep], `[[`, "smd")
cat(sprintf("Max SMD across covariates (median [IQR]): %.3f [%.3f–%.3f]\n",
            median(smds, na.rm=TRUE),
            quantile(smds, .25, na.rm=TRUE),
            quantile(smds, .75, na.rm=TRUE)))



library(doParallel); library(foreach) # I need chat to tell me what this is for
cl <- parallel::makeCluster(cores); registerDoParallel(cl)
res_list <- foreach(i=1:imp$m, .packages=c("MatchIt","survival","broom","mice")) %dopar% {
  do_one(i)
}
stopCluster(cl)