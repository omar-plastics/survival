# =============================================
# Title: Multiple imputation + PS matching + Cox ATT (cleaned)
# Author: Omar + Tutor
# Date: 2025-08-28
# Notes:
#  - Logic preserved from the original script. Layout, comments, and safety checks improved.
#  - Parallel uses the future ecosystem. The old doParallel/foreach block is left commented at bottom.
#  - If your R has no `futuremice`, consider `mice::parlmice(...)` as a drop-in parallel alternative.
# =============================================

# ==== 0) Packages ====
# Data I/O and manipulation
library(haven)     # read_sas for .sas7bdat
library(dplyr)     # mutate, filter, select, pipes
library(stringr)   # string utilities (loaded for completeness)

# Imputation and PS workflow
library(mice)      # multiple imputation by chained equations
library(MatchIt)   # propensity score matching
library(cobalt)    # covariate balance diagnostics

# Survival modeling and tidying
library(survival)  # coxph, Surv
library(broom)     # tidy model outputs
library(splines)   # natural cubic splines, ns()

# Parallel utilities
library(future)
library(future.apply)
library(progressr)

set.seed(2025)

# Optional: be nice to macOS Accelerate to avoid oversubscription
Sys.setenv(VECLIB_MAXIMUM_THREADS = "1")

# ==== 1) Read & minimal type hygiene ====
# Point this to your actual file path
# Example: "~/Documents/final_pub.sas7bdat"

sas_file <- "~/Developer/plastics/survival/data/raw/final_pub.sas7bdat"
cat_file <- "~/Developer/plastics/survival/data/raw/formats.sas7bcat"

if (file.exists(cat_file)) {
  dat <- haven::read_sas(sas_file, catalog_file = cat_file)
} else {
  dat <- haven::read_sas(sas_file)
}

# See which columns are 'labelled'
which_labelled <- vapply(dat, haven::is_labelled, logical(1))
sort(names(dat)[which_labelled])

# Outcome and key fields
# event = 1 for death; time = months from surgery (os_surg)
# Treat is RECON: 0 = Mastectomy only, 1 = Reconstruction

dat <- dat %>%
  mutate(
    # If OS_censor exists and in your prior SAS 1 meant death (inverted), fix here
    event = case_when(
      !is.na(OS_censor)        ~ as.integer(OS_censor == 1L),          # 1 = death
      !is.na(PUF_VITAL_STATUS) ~ as.integer(PUF_VITAL_STATUS == "0"),  # NCDB 0 = dead
      TRUE                     ~ NA_integer_
    ),
    time  = as.numeric(os_surg),
    
    # Treatment
    treat = factor(RECON, levels = c("0", "1"),
                   labels = c("Mastectomy only", "Reconstruction")),
    
    # Patient/context
    AGE_num  = suppressWarnings(as.numeric(AGE)),
    year_fac = factor(as.character(YEAR_OF_DIAGNOSIS)),
    race4    = factor(FINAL_RACE, levels = c("01","02","03","04"),
                      labels = c("NH White","NH Black","Hispanic","Asian/PI")),
    insure   = factor(INSURE, levels = c("0","1","2"),
                      labels = c("Uninsured","Government","Private")),
    cdcc_o   = factor(CDCC_TOTAL_BEST, ordered = TRUE, levels = c("0","1","2","3")),
    inc_q    = factor(INC_QUAR_STD,     ordered = TRUE, levels = c("1","2","3","4")),
    edu_q    = factor(edu_q,            ordered = TRUE, levels = c("1","2","3","4")),
    UR3      = factor(UR3, levels = c("M","U","R")),
    medexp   = factor(medexp, levels = c("0","1","2","3","U"),
                      labels  = c("Non-exp","Jan2014","Early10-13","Late>2014","Unknown")),
    fac_type = factor(FACILITY_TYPE_CD,   levels = c("1","2","3","4"),
                      labels = c("Community","Comprehensive","Academic","Integrated")),
    fac_div  = factor(FACILITY_LOCATION_CD, levels = as.character(1:9),
                      labels = c("NE","MidAtl","SouthAtl","ENC","ESC","WNC","WSC","Mountain","Pacific")),
    log_dist = ifelse(is.na(log_dist), log(1 + as.numeric(CROWFLY)), as.numeric(log_dist)),
    # Tumor components / biology
    size_mm    = as.numeric(size_mm),
    nodes_pos  = as.numeric(nodes_pos),
    nodes_exam = as.numeric(nodes_exam),
    grade_o    = factor(grade_o, ordered = TRUE, levels = c("1","2","3","4")),
    lvi_b      = factor(lvi_b, levels = c("0","1")),
    ER_bi      = factor(ER_bi, levels = c("0","1")),
    PR_bi      = factor(PR_bi, levels = c("0","1")),
    HER2_bi    = factor(HER2_bi, levels = c("0","1")),
    
    # Neoadjuvant indicators
    # Caution: as.logical("0") is TRUE in base R. If NEO_* are 0/1 strings, cast safely:
    # NEO_SYS = as.integer(NEO_SYS) == 1L, NEO_RT = as.integer(NEO_RT) == 1L
    NEO_SYS  = as.logical(NEO_SYS),
    NEO_RT   = as.logical(NEO_RT)
  )

# Drop rows without time or event or treat

dat <- dat %>% filter(!is.na(time), time >= 0, !is.na(event), !is.na(treat))

# ==== 2) PS covariates (component-based) ====

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

# Optional diagnostic: which covariates will be imputed?
na_summary <- dat %>%
  select(all_of(ps_covars)) %>%
  summarise(across(everything(), ~ mean(is.na(.)), .names = "propNA_{.col}"))
print(t(na_summary))

# ==== 3) Multiple imputation setup ====

mi_dat <- dat %>% select(all_of(c("treat","event","time", ps_covars)))

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
# Logical neoadjuvant -> treat as binary
meth[c("NEO_SYS","NEO_RT")] <- "logreg"
# Do NOT impute these:
meth[c("treat","event","time")] <- ""

# Predictor matrix (exclude treat/event/time as targets but allow as predictors)
pred <- quickpred(mi_dat, mincor = 0.05)
pred[ , c("treat","event","time")] <- 1
pred[c("treat","event","time"), ] <- 0

# ==== 4) Parallel imputation with future ====

plan(multisession, workers = 10)  # choose a sensible value for your box
options(future.wait.interval = 0.1)  # snappier progress polling

imp <- futuremice(
  mi_dat,
  m = 30, maxit = 20,
  method = meth, predictorMatrix = pred,
  seed = 2025,
  printFlag = FALSE
)

saveRDS(imp, "imp_m30_maxit20.rds")
# optional: qs::qsave(imp, ""imp_m30_maxit20.qs"")

# Pre-complete imputations to avoid shipping `imp` to every worker

datlist <- lapply(seq_len(imp$m), function(i) mice::complete(imp, i))

# ==== 5) One-imputation analysis: PS match + Cox ====

do_one <- function(dd, caliper = 0.20) {
  # Types
  dd <- dd %>% mutate(
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
  
  # Balance diagnostics (no printing)
  bt <- cobalt::bal.tab(m, un = FALSE, disp = NULL)
  bal_df <- as.data.frame(bt$Balance)
  smd_col <- grep("(Std\\.)?Diff.*Adj|Diff\\.Adj", names(bal_df), value = TRUE)
  smd_max <- if (length(smd_col)) max(abs(bal_df[[smd_col[1]]]), na.rm = TRUE) else NA_real_
  
  # Cox on matched sets; robust SE clustered by matched subclass
  fit <- survival::coxph(Surv(time, event) ~ treat,
                         data = md, robust = TRUE, cluster = subclass)
  est <- broom::tidy(fit)
  
  list(
    beta = est$estimate[est$term == "treatReconstruction"],  # log(HR)
    se   = est$std.error[est$term == "treatReconstruction"],
    smd  = smd_max,
    n    = nrow(md)
  )
}

# ==== 6) Run across imputations, then pool ====

res_list <- future_lapply(datlist, do_one, future.seed = TRUE)
plan(sequential)

# Pool results (drop failed imputations gracefully)
keep  <- sapply(res_list, function(x) is.finite(x$beta) && is.finite(x$se))
betas <- sapply(res_list[keep], `[[`, "beta")
ses   <- sapply(res_list[keep], `[[`, "se")
pooled <- mice::pool.scalar(Q = betas, U = ses^2, k = length(betas))

HR   <- exp(pooled$qbar)
seTot <- sqrt(pooled$t)
CI   <- exp(c(pooled$qbar - qt(0.975, df = pooled$df) * seTot,
              pooled$qbar + qt(0.975, df = pooled$df) * seTot))

cat(sprintf("ATT HR = %.3f (95%% CI %.3f–%.3f), p = %.4g\n", HR, CI[1], CI[2], pooled$pvalue))

# Optional: quick balance summary across imputations
smds <- sapply(res_list[keep], `[[`, "smd")
cat(sprintf("Max SMD across covariates (median [IQR]): %.3f [%.3f–%.3f]\n",
            median(smds, na.rm = TRUE),
            quantile(smds, 0.25, na.rm = TRUE),
            quantile(smds, 0.75, na.rm = TRUE)))

# ==== 7) Legacy alternative parallel backend (commented) ====
# library(doParallel); library(foreach)
# cores <- 10
# cl <- parallel::makeCluster(cores)
# doParallel::registerDoParallel(cl)
# res_list <- foreach(i = seq_len(imp$m), .packages = c("MatchIt","survival","broom","mice")) %dopar% {
#   # This was incorrect in the original script (passed index, not data).
#   # Correct pattern would be: dd <- mice::complete(imp, i); do_one(dd)
#   dd <- mice::complete(imp, i)
#   do_one(dd)
# }
# parallel::stopCluster(cl)