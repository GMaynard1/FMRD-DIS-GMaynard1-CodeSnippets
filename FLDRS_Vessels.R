## ---------------------------
## Script name: FLDRS_Vessels.R
##
## Purpose of script: Download a list of vessels that are currently using FLDRS
##    and categorize them by program code and groundfish sector (if applicable)
##
## Author: George A. Maynard
##
## Date Created: 2021-02-09
##
## Email: george.maynard@noaa.gov
##
## ---------------------------
## Notes:
##  This script requires the user to be connected to the NEFSC VPN and have   
##    have access to the NOvA and SOLE Oracle servers
## ---------------------------
## Set Working Directory
##
## ---------------------------
## Block scientific notation
options(scipen = 6, digits = 4)
## ---------------------------
## Load necessary packages
##
library(odbc)
library(DBI)
library(lubridate)
library(dplyr)
library(keyring)
library(writexl)
## ---------------------------
## Load necessary functions
##
## ---------------------------
## Connect to the SOLE database server
con_sole=dbConnect(
  odbc::odbc(),
  .connection_string=paste0(
    "DRIVER={Oracle in instantclient_12_2};DBQ=sole.nefsc.noaa.gov:1526/sole;UID=gmaynard;PWD=",
    keyring::backend_file$new()$get(
      service="SOLE",
      user="gmaynard",
      keyring="GMaynard_keyring"
    )
  ),
  timeout=10
)

## Connect to the NOVA databse server
con_nova=dbConnect(
  odbc::odbc(),
  .connection_string=paste0(
    "DRIVER={Oracle in instantclient_12_2};DBQ=nova.nefsc.noaa.gov:1526/nova;UID=gmaynard;PWD=",
    keyring::backend_file$new()$get(
      service="SOLE",
      user="gmaynard",
      keyring="GMaynard_keyring"
    )
  ),
  timeout=10
)

## Lock the keyring
keyring_lock("GMaynard_keyring")

## Query a data frame of all vessels, their program codes, and expiration dates
VP=dbGetQuery(
  con_sole,
  'SELECT * FROM FVTR.VERS_VESSEL_PROGRAMS'
)

## Convert the expiration (end date) to a POSIX data type
VP$VVP_END_DATE=ymd_hms(VP$VVP_END_DATE)

## Select only those vessel/program lines with a NA value in the expiration date
##    column (i.e., only those vessels that are active in at least one program)
##    or those that have become inactive in the last year. 
VP=subset(
  VP,
  is.na(VP$VVP_END_DATE)|VP$VVP_END_DATE>=ymd("2020-01-01")
)

## Download a data frame of vessel permit information
VES=dbGetQuery(
  con_sole,
  'SELECT * FROM FVTR.FVTR_VESSELS'
)

## Subset out only the vessels that exist in vessel program data frame
VES=subset(
  VES,
  VES$AP_NUM%in%VP$FV_AP_NUM
)

## Merge the vessel permit information data frame with the vessel program data
##    frame to create a new data frame
VES$FV_AP_NUM=VES$AP_NUM
new=merge(VES,VP)
new$ID=gsub(
  " ",
  "",
  toupper(
    paste0(new$VESSEL_NAME,new$VESSEL_HULL_ID)
  )
)

## Download a data frame of all of the sector affiliations
SECTOR=dbGetQuery(
  con_nova,
  'SELECT * FROM OBDBS.SECTOR_VESSELS_MV'
)

## Subset out only sector vessels that exist in the new merged data frame
SECTOR=subset(
  SECTOR,
  SECTOR$HULLNUM%in%new$VESSEL_HULL_ID
)
SECTOR$ID=gsub(
  " ",
  "",
  toupper(
    paste0(SECTOR$VESNAME,SECTOR$HULLNUM)
  )
)

## Build a new data frame that includes all relevant information in a cleaner
##    format
VesselData=data.frame(
  VesselName=as.character(),
  HullNumber=as.character(),
  PermitNumber=as.character(),
  SectorMember=as.character(),
  Sector=as.character(),
  ProgramCodes=as.character()
)

## Remove known test vessels from the dataset
new=subset(
  new,
  new$VESSEL_NAME%in%c("TENNESSEE JED","STELLA BLUE","CHINA CAT SUNFLOWER")==FALSE
)

## Loop over each unique vessel in the merged data frame
for(i in unique(new$ID)){
  ## Subset out all records associated with that vessel
  x=subset(new,new$ID==i)
  ## Create a new line of data to be added to the VesselData dataframe
  newLine=data.frame(
    VesselName=unique(x$VESSEL_NAME),
    HullNumber=unique(x$VESSEL_HULL_ID),
    PermitNumber=unique(x$VESSEL_PERMIT_NUM),
    SectorMember=as.character(i%in%SECTOR$ID),
    Sector=ifelse(
      i%in%SECTOR$ID,
      unique(as.character(subset(SECTOR,SECTOR$ID==i)$SECTOR_NAME)),
      NA),
    ProgramCodes=paste(x$VP_PROGRAM_CODE,sep="",collapse=",")
  )
  ## Add the new line to the final data frame
  VesselData=rbind(VesselData,newLine)
}

## Read in a list of program codes to support the data
programs=dbGetQuery(
  con_sole,
  'SELECT * FROM FVTR.VERS_PROGRAMS'
)

## Select only those programs that exist within the FLDRS data
programs=subset(
  programs,
  programs$PROGRAM_CODE%in%unique(
    strsplit(
      paste(
        VesselData$ProgramCodes,
        sep=",",
        collapse=","
        ),
      ","
      )[[1]]
    )
  )

## Read in FLDRS trip submission data
trips=dbGetQuery(
  con_sole,
  'SELECT * FROM FVTR.VERS_TRIP_LIST'
)

## Format the trip upload dates to datetime objects
trips$SailDate=ymd_hms(trips$SAIL_DATE_LCL)
trips$UploadDate=ymd_hms(trips$UPLOAD_DATE_LCL)

## Subset out only those trips that have taken place within the last twelve months
target=Sys.Date()-months(12)
trips=subset(
  trips,
  trips$SailDate>=target|trips$UploadDate>=target
)

## Add columns to the VesselData table indicating the most recent trip for each
##    vessel and the trip type
VesselData$MostRecent=NA
VesselData$MR_EVTR=NA
VesselData$EVTR=NA
VesselData$SECTORTRIP=NA
VesselData$STFLT=NA
VesselData$NCRP=NA
VesselData$ECLAMS=NA
VesselData$EM=NA
for(i in 1:nrow(VesselData)){
  x=subset(
    trips,
    trips$VESSEL_HULL_ID==VesselData$HullNumber[i]
  )
  VesselData$MostRecent[i]=ifelse(
    nrow(x)==0,
    NA,
    as.character(max(c(x$SailDate,x$UploadDate)))
  )
  VesselData$MR_EVTR[i]=ifelse(
    sum(x$EVTR)>0,
    as.character(max(subset(x,x$EVTR==1)$UploadDate)),
    NA
  )
  if(nrow(x)!=0){
    if(max(c(x$SailDate,x$UploadDate))%in%c(x$UploadDate)){
      y=x[which(x$UploadDate==max(x$UploadDate)),]
    } else {
      if(max(c(x$SailDate,x$UploadDate))%in%c(x$SailDate)){
        y=x[which(x$SailDate==max(x$SailDate)),]
      }
    }
  } else {
    y=rep(NA,ncol(x))
  }
  if(sum(is.na(y))<ncol(x)){
    VesselData$EVTR[i]=y$EVTR
    VesselData$SECTORTRIP[i]=y$SECTOR
    VesselData$STFLT[i]=y$STFLT
    VesselData$NCRP[i]=y$NCRP
    VesselData$ECLAMS[i]=y$ECLAMS
    VesselData$EM[i]=y$EM
  } else {
    VesselData$EVTR[i]=NA
    VesselData$SECTORTRIP[i]=NA
    VesselData$STFLT[i]=NA
    VesselData$NCRP[i]=NA
    VesselData$ECLAMS[i]=NA
    VesselData$EM[i]=NA
  }
}
## Create a table of total participating vessels by type
totals=data.frame(
  desc=c(
    "all vessels (including inactive)",
    "vessels that have submitted data through FLDRS since 2020-01-01",
    "vessels that have submitted an eVTR through FLDRS since 2020-01-01",
    "vessels participating in study fleet programs",
    "vessels participating in cooperative research (unpaid)",
    "clam vessels using FLDRS",
    "electronic monitoring participants using FLDRS"
  ),
  totalVessels=c(
    nrow(VesselData),
    nrow(subset(
      VesselData,
      (VesselData$EVTR+VesselData$SECTORTRIP+VesselData$STFLT+VesselData$NCRP+VesselData$ECLAMS+VesselData$EM)>0
      )
    ),
    sum(VesselData$EVTR,na.rm=TRUE),
    sum(VesselData$STFLT,na.rm=TRUE),
    sum(VesselData$NCRP,na.rm=TRUE),
    sum(VesselData$ECLAMS,na.rm=TRUE),
    sum(VesselData$EM,na.rm=TRUE)
  )
)

## Create a new table of programs and vessel participation
vps=matrix(nrow=nrow(VesselData),ncol=nrow(programs)+2)
vps=as.data.frame(vps)
colnames(vps)=c("VesselName","VID",programs$PROGRAM_DESCR)
for(i in 1:nrow(VesselData)){
  vps[i,1]=VesselData$VesselName[i]
  vps[i,2]=gsub(
    pattern=" ",
    replacement="",
    x=paste0(VesselData$VesselName[i],VesselData$HullNumber[i])
  )
  for(j in colnames(vps)[3:ncol(vps)]){
    vps[i,j]=grepl(programs$PROGRAM_CODE[which(programs$PROGRAM_DESCR==j)],VesselData$ProgramCodes[i])
  }
}

## Create an Identifier column by concatenating vessel name and hull number
##    in the vessel data frame
VesselData$VID=gsub(" ","",paste0(VesselData$VesselName,VesselData$HullNumber))

## Use the Identifier column (VID) to merge vessel data and program data
x=merge(VesselData,vps)

## Clean up the data frame
x$VID=NULL

## Export the data to an excel spreadsheet for the end users
write_xlsx(
  list(
    Totals=totals,
    VesselData=x,
    SectorAffiliations=SECTOR,
    VesselIdentifiers=VES,
    ProgramParticipation=VP,
    ProgramCodes=programs
    ),
  path="VesselData.xlsx"
  )
