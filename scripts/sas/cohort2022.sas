dm 'log;clear;output;clear;odsresults;clear';
options mprint nodate pageno=1;
%SYSMSTORECLEAR;
LIBNAME library 'Y:\Documents\Research Folder\SAS Folder\NCDB Files\NCDB PUF 2022 Instruction';

/* ---------- FORMATS YOU CAN KEEP ---------- */
proc format library=library;
  value $ffacility  '1'='Community Cancer Program' '2'='Comprehensive Community Cancer Program'
                    '3'='Academic/Research Program' '4'='Integrated Network Cancer Program' '9'='Other';
  value $ffac_location '1'='New England' '2'='Middle Atlantic' '3'='South Atlantic' '4'='East North Central'
                       '5'='East South Central' '6'='West North Central' '7'='West South Central' '8'='Mountain' '9'='Pacific';
  value $ffinal_race '01'='White' '02'='Black' '03'='Hispanic' '04'='Asian/PI';
  value $finsure   '0'='Not Insured' '1'='Government Insurance' '2'='Private Insurance';
  value $fagestrata '01'='18 - 30' '02'='31 - 40' '03'='41 - 50' '04'='51 - 65' '05'='66 - 80';
  value $fvital '0'='Dead' '1'='Alive';
  value $fcdcc '0'='0' '1'='1' '2'='2' '3'='>= 3';
  value $fstage '0'='Stage 0' '1'='Stage I' '2'='Stage II' '3'='Stage III';
  value $freadmission '0'='No surgery or not readmitted' '1'='Unplanned readmit ≤30d' '2'='Planned ≤30d'
                      '3'='Planned + unplanned ≤30d' '9'='Unknown';
  value $fradlocation '0'='No RT' '1'='All at this facility' '2'='Regional here, boost elsewhere'
                      '3'='Boost here, regional elsewhere' '4'='All elsewhere' '8'='Other' '9'='Unknown';
  value $fsurgradseq 0='No RT and/or no surgery' 2='RT before surgery' 3='RT after surgery' 4='RT before and after'
                     5='IORT' 6='IORT + other Rx' 7='Surgery before and after RT' 9='Unknown';
  value $f90day '0'='Alive or died >90d' '1'='Died <= 90d' '9'='No surgery or < 90d FU';
  /* neighborhood formats for unified derived vars below */
  value $finc_std '1'='Q1 (lowest)' '2'='Q2' '3'='Q3' '4'='Q4 (highest)';
  value $fedu_std '1'='Highest % w/o HS' '2'='Mid-high' '3'='Mid-low' '4'='Lowest % w/o HS';
  value $fsurg '0'='Mastectomy only' '1'='Implant-based recon' '2'='Autologous recon';
  value $frecon '0'='Mastectomy' '1'='Any reconstruction';
  value $frads  '0'='No Radiation' '1'='Radiation';
run;

data pub_keep;
  set ncdb_puf2022 (keep=
    /* IDs & timing */
    PUF_CASE_ID YEAR_OF_DIAGNOSIS TNM_EDITION_NUMBER

    /* Cohort guardrails */
    SEX PRIMARY_SITE LATERALITY HISTOLOGY BEHAVIOR DIAGNOSTIC_CONFIRMATION
    CLASS_OF_CASE SEQUENCE_NUMBER

    /* Demographics & access */
    AGE RACE SPANISH_HISPANIC_ORIGIN INSURANCE_STATUS
    FACILITY_TYPE_CD FACILITY_LOCATION_CD
    UR_CD_03 UR_CD_13 CROWFLY
    MED_INC_QUAR_12 NO_HSD_QUAR_12
    MED_INC_QUAR_2016 NO_HSD_QUAR_2016
    PUF_MEDICAID_EXPN_CODE CDCC_TOTAL_BEST 
	READM_HOSP_30_DAYS PUF_90_DAY_MORT_CD

    /* Tumor components & biology (for component PSM) */
    GRADE
    TUMOR_SIZE TUMOR_SIZE_SUMMARY_2016
    REGIONAL_NODES_POSITIVE REGIONAL_NODES_EXAMINED
    LYMPH_VASCULAR_INVASION
    CS_SITESPECIFIC_FACTOR_1  /* ER */
    CS_SITESPECIFIC_FACTOR_2  /* PR */
    CS_SITESPECIFIC_FACTOR_15 /* HER2 */

    /* Stage (for cohorting/descriptives/sensitivity only) */
    TNM_CLIN_STAGE_GROUP TNM_PATH_STAGE_GROUP ANALYTIC_STAGE_GROUP

    /* Metastasis guards */
    CS_METS_AT_DX             /* pre-2016 */
    METS_AT_DX_OTHER METS_AT_DX_DISTANT_LN METS_AT_DX_BONE
    METS_AT_DX_BRAIN METS_AT_DX_LIVER METS_AT_DX_LUNG  /* 2016–2017 */

    /* Exposure (surgery) */
    RX_HOSP_SURG_PRIM_SITE
    RX_SUMM_SURG_PRIM_SITE
    RX_SUMM_SCOPE_REG_LN_2012  /* SLNB/ALND scope (QC/desc) */

    /* Radiation (sequence only; for PMRT sensitivity) */
    RX_SUMM_SURGRAD_SEQ
    RAD_LOCATION_OF_RX

    /* Outcome (overall survival from surgery) */
    DX_DEFSURG_STARTED_DAYS
    DX_LASTCONTACT_DEATH_MONTHS
    PUF_VITAL_STATUS

    /* Admin/QC flags (sensitivities) */
    PUF_MULT_SOURCE
    PUF_REFERENCE_DATE_FLAG
  );
run;
/* ===========================================
   DATA STEP: Build pub1 cohort and features
   =========================================== */
data pub1;
  set pub_keep;

  /* -------------------------------------------
     VARIABLE ATTRIBUTES: LENGTH
     ------------------------------------------- */
  length
    /* categorical flags */
    AGESTRATA    $2
    STAGE        $1
    FINAL_RACE   $2
    INSURE       $1
    RADS         $1
    SURG         $1
    RECON        $1

    /* SES quartiles (standardized by era) */
    INC_QUAR_STD $1
    EDU_QUAR_STD $1

    /* helpers */
    medexp $1
    _p     $3
    _c     $3
    UR_STD $1
    UR3    $1

    /* biology */
    ER_bi  $1
    PR_bi  $1
    HER2_bi $1
  ;

  /* explicit numeric lengths (default 8, listed here for clarity) */
  length
    dist        8
    log_dist    8
    os_surg     8
    size_mm_raw 8
    size_mm     8
    nodes_pos   8
    nodes_exam  8
    hist        8
  ;

  /* -------------------------------------------
     VARIABLE ATTRIBUTES: FORMATS
     ------------------------------------------- */
  format
    PUF_VITAL_STATUS         $fvital.
    CDCC_TOTAL_BEST          $fcdcc.
    STAGE                    $fstage.
    READM_HOSP_30_DAYS       $freadmission.
    RAD_LOCATION_OF_RX       $fradlocation.
    PUF_90_DAY_MORT_CD       $f90day.
    INSURE                   $finsure.
    FINAL_RACE               $ffinal_race.
    AGESTRATA                $fagestrata.
    SURG                     $fsurg.
    RECON                    $frecon.
    RADS                     $frads.
    INC_QUAR_STD             $finc_std.
    EDU_QUAR_STD             $fedu_std.
    RX_SUMM_SURGRAD_SEQ      $fsurgradseq.
  ;

  /* -------------------------------------------
     LABELS
     ------------------------------------------- */
  label
    medexp   = 'Medicaid expansion group (state of residence)'
    os_surg  = 'Months (OS)'
    dist     = 'Crowfly distance (mi, winsorized at 500)'
    log_dist = 'log(1+distance)'
  ;

  /* -------------------------------------------
     SIMPLE DERIVATIONS
     ------------------------------------------- */
  medexp = PUF_MEDICAID_EXPN_CODE;
  if medexp in ('','9') then medexp = 'U';  /* unknown group */

  /* ===========================================
     1) COHORT FILTERS
     =========================================== */

  /* Diagnosis year window: AJCC 7th era */
  if YEAR_OF_DIAGNOSIS < 2010 or YEAR_OF_DIAGNOSIS > 2017 then delete; *183042*;

  /* Female patients */
  if SEX ne '2' then delete; *1814997*;

  /* Primary breast sites only */
  if not (PRIMARY_SITE in ('C500','C501','C502','C503','C504','C505','C506','C508','C509')) then delete; *1814997*;

  /* Behavior: keep in situ or invasive (2=in situ, 3=invasive) */
  if not (BEHAVIOR in ('2','3')) then delete;

  /* AJCC edition: enforce 7th */
  if TNM_EDITION_NUMBER ne '07' then delete; *1813081*;

  /* Follow-up validity */
  if missing(PUF_VITAL_STATUS) then delete;
  if DX_LASTCONTACT_DEATH_MONTHS < 0 then delete; *1812975*;

  /* Age window and 10-year strata */
  if AGE = 999 or AGE < 40 or AGE > 80 then delete;  /* exclude <40 and >80; 999=unknown */
  if 40 <= AGE <= 50 then AGESTRATA='01';
  else if 51 <= AGE <= 60 then AGESTRATA='02';
  else if 61 <= AGE <= 70 then AGESTRATA='03';
  else if 71 <= AGE <= 80 then AGESTRATA='04'; *1593442*;

  /* Neighborhood SES: pick correct vintage by year (avoid 2020-era vars) */
  if YEAR_OF_DIAGNOSIS >= 2016 then INC_QUAR_STD = MED_INC_QUAR_2016;
  else                               INC_QUAR_STD = MED_INC_QUAR_12;

  if YEAR_OF_DIAGNOSIS >= 2016 then EDU_QUAR_STD = NO_HSD_QUAR_2016;
  else                               EDU_QUAR_STD = NO_HSD_QUAR_12;

  /* Insurance recode: 0=uninsured, 1=government, 2=private */
  select (INSURANCE_STATUS);
    when ('0')           INSURE='0';  /* uninsured */
    when ('1')           INSURE='2';  /* private */
    when ('2','3','4')   INSURE='1';  /* Medicaid, Medicare, other gov */
    otherwise delete; *1566514*;
  end;

  /* Race/Hispanic recode: 01=NH White, 02=NH Black, 03=Hispanic, 04=Other */
  if      SPANISH_HISPANIC_ORIGIN in ('1','2','3','4','5','6','7','8') then FINAL_RACE='03';
  else if RACE='01'                                                    then FINAL_RACE='01';
  else if RACE='02'                                                    then FINAL_RACE='02';
  else if RACE in (
           '04','05','06','07','08','10','11','12','13','14','15','16','17',
           '20','21','22','25','26','27','28','30','31','32','96','97'
         ) then FINAL_RACE='04';
  else delete; *1541142*;

  /* Survival censoring indicator: 1=censored (alive at last contact), 0=event */
  if PUF_VITAL_STATUS = '0' then OS_censor = 1;
  else                           OS_censor = 0;

  /* Overall survival from surgery start (months) */
  os_surg = round(DX_LASTCONTACT_DEATH_MONTHS - DX_DEFSURG_STARTED_DAYS/(365.2425/12), 0.01);

  /* ===========================================
     2) EXPOSURE: SURGERY & RECONSTRUCTION
        HOSP-anchored, SUMM-screened
        Universe: total/simple mastectomy
     =========================================== */

  RECON = '0';
  SURG  = '';

  /* Exclude any record with contralateral prophylactic mastectomy (CPM) */
  if RX_HOSP_SURG_PRIM_SITE in ('42','47','48','49','75') then delete;
  if RX_SUMM_SURG_PRIM_SITE in ('42','47','48','49','75') then delete;

  /* Restrict HOSP to total/simple mastectomy family + NSM (30) */
  if not (RX_HOSP_SURG_PRIM_SITE in ('30','40','41','43','44','45','46')) then delete;

  /* Exclude cases where SUMMARY shows non-mastectomy or a different family */
  if RX_SUMM_SURG_PRIM_SITE in (
        '20','21','22','23','24',                                   /* breast-conserving */
        '50','51','52','53','54','55','56','57','58','59','63',     /* modified radical */
        '60','61','62','64','65','66','67','68','69','73','74',     /* radical */
        '70','71','72','76','80'                                    /* extended, bilateral-single-tumor, NOS */
     ) then delete; *534426*;

  /* Treated group: reconstruction at reporting facility */
  if RX_HOSP_SURG_PRIM_SITE in ('30','43','44','45','46') then do;
    RECON = '1';
    /* Map to 3-level SURG:
       45=implant -> '1'
       44=autologous -> '2'
       30/43/46 (NSM/NOS/combined) -> group with implant -> '1' */
    if      RX_HOSP_SURG_PRIM_SITE='45' then SURG='1';
    else if RX_HOSP_SURG_PRIM_SITE='44' then SURG='2';
    else                                  SURG='1';
  end;

  /* Controls: no reconstruction anywhere in first course (HOSP and SUMM both 40/41) */
  else if RX_HOSP_SURG_PRIM_SITE in ('40','41') then do;
    if RX_SUMM_SURG_PRIM_SITE in ('40','41') then do;
      RECON='0';
      SURG='0';
    end;
    else delete;  /* SUMMARY indicates recon or other -> not a true non-recon control */
  end;
  else delete; *248276*;

  if missing(SURG) then delete;

  /* ===========================================
     3) STAGE DERIVATION (prefer pathologic)
     =========================================== */
  _p = strip(TNM_PATH_STAGE_GROUP);
  _c = strip(TNM_CLIN_STAGE_GROUP);

  if      substr(_p,1,1) in ('0','1','2','3') then STAGE = substr(_p,1,1);
  else if substr(_c,1,1) in ('0','1','2','3') then STAGE = substr(_c,1,1);
  else delete; /*243,451*/

  /* ===========================================
     4) GEOGRAPHY & DISTANCE
     =========================================== */
  /* Rural-urban code by year */
  if YEAR_OF_DIAGNOSIS <= 2012 then UR_STD = UR_CD_03;
  else                             UR_STD = UR_CD_13;

  /* Collapse to 3 levels: M=metro, U=urban (non-metro), R=rural */
  if      UR_STD in ('1','2','3')     then UR3='M';
  else if UR_STD in ('4','5','6','7') then UR3='U';
  else if UR_STD in ('8','9')         then UR3='R';
  else                                     UR3='';  /* missing */

  /* Crow-fly distance (winsorized at 500 miles) and log transform */
  dist = input(CROWFLY, best.);
  if dist > 500 then dist = 500;
  log_dist = log(1 + dist);

  /* ===========================================
     5) PRIMARY TUMOR FILTERS
     =========================================== */
  /* First or only malignant primary */
  if not (SEQUENCE_NUMBER in ('00','01')) then delete;

  /* Exclude non-epithelial histologies (codes below) */
  hist = input(HISTOLOGY, 8.);
  if (8720 <= hist <= 8790) or
     (8800 <= hist <= 8936) or
     (hist = 9020)        or
     (9050 <= hist <= 9091) or
     (9140 <= hist <= 9589) or
     (9590 <= hist <= 9992) then delete;

  /* Histology confirmation required */
  if DIAGNOSTIC_CONFIRMATION ne '1' then delete;

  /* ===========================================
     6) BIOLOGY: ER / PR / HER2 (binary; else missing)
     =========================================== */

  /* ER: prefer SSDI ER_SUMMARY (0=neg, 1=pos); else CS SSF1 (010=pos, 020=neg)
     Here we use CS SSF fallbacks as in your code */
  if      CS_SITESPECIFIC_FACTOR_1='010' then ER_bi='1';
  else if CS_SITESPECIFIC_FACTOR_1='020' then ER_bi='0';
  else                                    ER_bi='';  /* 030/000/996/997/998/999/blank -> missing */

  /* PR: prefer SSDI PR_SUMMARY; else CS SSF2 (010=pos, 020=neg) */
  if      CS_SITESPECIFIC_FACTOR_2='010' then PR_bi='1';
  else if CS_SITESPECIFIC_FACTOR_2='020' then PR_bi='0';
  else                                    PR_bi='';  /* 030/000/996/997/998/999 -> missing */

  /* HER2: prefer SSDI HER2_OVERALL_SUMM (0=neg, 1=pos; 2=equivocal -> missing)
     else CS SSF15 (010=pos, 020=neg) */
  if      CS_SITESPECIFIC_FACTOR_15='010' then HER2_bi='1';
  else if CS_SITESPECIFIC_FACTOR_15='020' then HER2_bi='0';
  else                                     HER2_bi='';  /* 030/988/997/998/999/other -> missing */

  /* ===========================================
     Radiation sequence relative to surgery
     =========================================== */
  length NEO_RT PMRT RT_unknown 3;
  RT_unknown = 0; NEO_RT = 0; PMRT = 0; RADS = '0';

  _seq = input(RX_SUMM_SURGRAD_SEQ, 8.);

  if      _seq = 0 then RADS = '0';                    /* no RT */
  else if 2 <= _seq <= 7 then do;                      /* some RT occurred */
    RADS = '1';
    if _seq in (2,4,7) then NEO_RT = 1;                /* pre-op components */
    if _seq in (3,4,7) then PMRT  = 1;                 /* post-op components */
  end;
  else do;                                             /* 9=unknown or nonstandard */
    RADS = '0';       /* treat as no RT for primary description */
    RT_unknown = 1;   /* keep a flag for sensitivity */
  end;
  drop _seq;

  /* ===========================================
     Neoadjuvant systemic therapy indicator
     (pre-surgery confounder — include in PSM)
     =========================================== */
  NEO_SYS = (RX_SUMM_SYSTEMIC_SUR_SEQ in ('2','4'));  /* 2=before; 4=before+after */

  /* ===========================================
     8) TUMOR SIZE / NODES / GRADE / LVI / SES / CHARLSON
     =========================================== */

  /* Tumor size (mm): source varies by year; set special codes to missing */
  if YEAR_OF_DIAGNOSIS <= 2015 then size_mm_raw = input(TUMOR_SIZE, 8.);
  else                               size_mm_raw = input(TUMOR_SIZE_SUMMARY_2016, 8.);
  size_mm = size_mm_raw;
  if size_mm in (0,989,990,998,999) then size_mm = .;
  /* Notes: 989 = 989+ mm; 990 = <1 mm; 998/999 = diffuse or missing. */

  /* Nodes: recode special values to missing (final policy) */
  nodes_pos  = input(REGIONAL_NODES_POSITIVE, 8.);
  nodes_exam = input(REGIONAL_NODES_EXAMINED, 8.);
  if nodes_pos  in (90,95,97,98,99) then nodes_pos  = .;
  if nodes_exam in (90,95,96,97,98,99) then nodes_exam = .;

  /* Grade (ordered) */
  grade_o = GRADE;
  if grade_o='9' then grade_o = '';

  /* Lymphovascular invasion (binary); '8' excluded per your rule */
  lvi_b = LYMPH_VASCULAR_INVASION;
  if lvi_b in ('9') then lvi_b = '';
  if lvi_b = '8' then delete;

  /* SES quartiles (ordered) */
  inc_q = INC_QUAR_STD; if inc_q='9' then inc_q='';
  edu_q = EDU_QUAR_STD; if edu_q='9' then edu_q='';

run;
data library.final_pub;
  set pub1;
  drop 
    /* Vintage SES (kept unified INC_QUAR_STD / EDU_QUAR_STD) */
    MED_INC_QUAR_12 MED_INC_QUAR_2016
    NO_HSD_QUAR_12 NO_HSD_QUAR_2016

    /* Vintage rural-urban (kept UR_STD / UR3) */
    UR_CD_03 UR_CD_13

    /* Non-informative after filtering */
    TNM_EDITION_NUMBER

    /* Redundant if using your derived STAGE */
    ANALYTIC_STAGE_GROUP

    /* Raw biomarker SSFs (kept ER_bi / PR_bi / HER2_bi) */
    CS_SITESPECIFIC_FACTOR_1
    CS_SITESPECIFIC_FACTOR_2
    CS_SITESPECIFIC_FACTOR_15

    /* Stage helpers (used to compute STAGE) */
    _p _c

    /* Medicaid expansion source (kept medexp) */
    PUF_MEDICAID_EXPN_CODE

    /* Not used in analysis (unless you need them) */
    PUF_MULT_SOURCE
    PUF_REFERENCE_DATE_FLAG

    /* Constant in this cohort (after QA you can drop) */
    DIAGNOSTIC_CONFIRMATION
  ;
run;

proc contents data=final_pub; run;
