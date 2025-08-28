# ==== 0) Packages ====
library(haven)     # read_sas
library(dplyr)
library(stringr)
library(mice)
library(MatchIt)
library(cobalt)    # balance diagnostics
library(survival)
library(broom)

set.seed(2025)

# ==== 1) Read & minimal type hygiene ====
dat <- read_sas("~/Developer/plastics/survival/data/raw/final_pub.sas7bdat")

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

imp <- mice(mi_dat, m = 30, maxit = 20, method = meth, predictorMatrix = pred, printFlag = TRUE, seed = 2025)



# okay so first i must impute the missing values
# Then in must do the propensity score match

# How do i know which values I'm going to impute?