#!/bin/bash

# -------------------------------------------------------
#   How To Use
# -------------------------------------------------------

# Exit if any statement returns a non-true value
set -e

# Define various output colors
cecho () {
  local _color=$1; shift
  # If running via cron, don't use colors.
  if tty -s
  then
  	echo -e "$(tput setaf $_color)$@$(tput sgr0)"
  else
  	echo $1
  fi
}
black=0; red=1; green=2; yellow=3; blue=4; pink=5; cyan=6; white=7;

help () {
	echo
	cecho $blue "LVM RESCRIPT & RESTIC BACKUP"
	cecho $blue "----------------------------"
	cecho $blue "Author:  Sebastian Plocek"
	cecho $blue "URL:     https://github.com/sebastian13/lvm-restic-backup"
	echo
	cecho $blue  "Usage:"
	cecho $blue  "  lvm-rescript [repo_name] [command] [lv_name|path-to-list]"
	echo
	cecho $blue  "Commands:"
	cecho $blue  "  block-level-backup          Creates a lvm-snapshot & pipes the volume using dd to restic"
	cecho $blue  "  block-level-gz-backup       Creates a lvm-snapshot & pipes the volume using dd and pigz to restic"
	cecho $blue  "  file-level-backup           Creates a lvm-snapshot & creates a restic backup using the mounted snapshot"
	cecho $blue  "  restore                     Restores logical volume(s)"
	echo
	cecho $blue  "Logical Volume:"
	cecho $blue  "  Provide the LV name without VG."
	cecho $blue  "  Provide the path to a list of LV names. LVs listed as #comment won't be backed up."
	echo
}

# initialise variables
CURRDIR="$(dirname "$(readlink -f "$0")")"
RESTIC_EXCLUDE="/etc/restic/exclude.txt"
LVM_SNAPSHOT_BUFFER="10G"
WORKDIR="/"

# Change to WORKDIR
# Restic will save this path
cd $WORKDIR

# Create Log Directory
LOGDIR="/var/log/lvm-restic"
mkdir -p $LOGDIR
RLOG="${LOGDIR}/lvm-rescript-running.log"

# -------------------------------------------------------
#   Check package availability
# -------------------------------------------------------

command -v restic >/dev/null 2>&1 || { echo "[Error] Please install restic"; exit 1; }
command -v rescript >/dev/null 2>&1 || { echo "[Error] Please install rescript"; exit 1; }

# -------------------------------------------------------
#   Loop to load arguments
# -------------------------------------------------------

# if no argument, display help
if [ $# -eq 0 ]
then
	help
	exit
fi

case "$1" in
	help)
		help
		exit
		;;
esac

# -------------------------------------------------------
#   Load Repository Details
# -------------------------------------------------------
repo="$1"
rescript_dir="$HOME/.rescript"
config_dir="$rescript_dir/config"
config_file="$config_dir/$repo.conf"

# Check if repo config exists
if [[ ! -e "$config_dir/$1.conf" && ! -e "$config_dir/$1.conf.gpg" ]] ; then
	echo "There is no repo or command for [$1]. Indicate a valid"
	echo "repo name or command to proceed. Run [lvm-rescript help] for usage."
	exit
fi

# Check if the repository exists
echo "[INFO] Looking for your restic repository. Please be patient."
rescript ${repo} snapshots > /dev/null 2>&1 || { echo "[Error]"; rescript ${repo} snapshots; exit 1; }

source "$config_file"
export RESTIC_REPOSITORY="$RESTIC_REPO"
export B2_ACCOUNT_ID="$B2_ID"
export B2_ACCOUNT_KEY="$B2_KEY"
export AWS_ACCESS_KEY_ID="$AWS_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_KEY"
export AZURE_ACCOUNT_NAME="$AZURE_NAME"
export AZURE_ACCOUNT_KEY="$AZURE_KEY"
export GOOGLE_PROJECT_ID="$GOOGLE_ID"
export GOOGLE_APPLICATION_CREDENTIALS="$GOOGLE_CREDENTIALS"
if [[ "$RESCRIPT_PASS" ]] ; then
  export RESTIC_PASSWORD="$RESCRIPT_PASS"
else
  export RESTIC_PASSWORD="$RESTIC_PASSWORD"
fi


# -------------------------------------------------------
#   Wait for any other restic backup to finish
# -------------------------------------------------------

while (pgrep -x restic)
do
    echo "[INFO] Waiting for the listed restic processes to finish"
    sleep 60
done


# -------------------------------------------------------
#   The backup tasks
# -------------------------------------------------------

failed () {
	echo
	echo " ___              ___  __  "
	echo "|__   /\  | |    |__  |  \ "
	echo "|    /--\ | |___ |___ |__/ "
	echo                          
	exit 1
}

all-done () {
	echo "                   __   __        ___ "
	echo " /\  |    |       |  \ /  \ |\ | |__  "
	echo "/--\ |___ |___    |__/ \__/ | \| |___ "
	echo       
	exit 0                            
}

# -------------------------------------------------------
#   Cleaning Functions
# -------------------------------------------------------

clean-snapshot () {
	# Look for old snapshots of ${SNAPSHOT_PATH}
	if (lvs -o lv_path --noheadings -S "lv_attr=~[^s.*]" | grep -wo "${SNAPSHOT_PATH}")
	then
		cecho $red "[WARNING] ${SNAPSHOT_NAME} already exists."
		cecho $red "          I will remove it in 5 seconds!"
		sleep 5
		lvremove -f ${SNAPSHOT_PATH}
	fi
}

clean-all-snapshots () {
	# Look for old snapshots
	ACTIVE_SNAPSHOTS=$(lvs -o lv_path --noheadings -S "lv_attr=~[^s.*]" | tr -d '  ' | grep "_snapshot$")
	if [ ! -z "$ACTIVE_SNAPSHOTS" ]
	then
		cecho $red "Removing the following active snapshots:"
		cecho $red "${ACTIVE_SNAPSHOTS}"
		echo
		sleep 5
		for i in ${ACTIVE_SNAPSHOTS}
		do
			lvremove -f $i
		done
	fi
}

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
ctrl_c () {
		echo
		cecho $red "======================================================="
		cecho $red "Trapped CTRL-C"
		cecho $red "Signal interrupt received, cleaning up"
		echo
        clean-all-snapshots
        exit 130
}

# -------------------------------------------------------
#   Backup Functions
# -------------------------------------------------------

# Block Level Backup piped to restic
block-level-backup () {
	dd if=${SNAPSHOT_PATH} bs=4M status=none | \
		restic backup \
		--verbose \
		--tag LV \
		--tag block-level-backup \
		--tag ${BACKUP_LV_SIZE}g_size \
		--tag ${LV_TO_BACKUP} \
		--stdin \
		--stdin-filename ${BACKUP_LV}.img | \
		tee -a ${LOGDIR}/lvm-restic-block-level-backup.log | \
		tee ${RLOG}
	echo
}

block-level-gz-backup () {
	command -v pigz >/dev/null 2>&1 || { echo "[Error] Please install pigz"; exit 1; }

	dd if=${SNAPSHOT_PATH} bs=4M status=none | \
		pigz --fast --rsyncable | \
		restic backup \
		--verbose \
		--tag LV \
		--tag block-level-backup \
		--tag pigz \
		--tag ${LV_TO_BACKUP} \
		--tag ${BACKUP_LV_SIZE}g_size \
		--stdin \
		--stdin-filename ${BACKUP_LV}.img.gz | \
		tee -a ${LOGDIR}/lvm-restic-block-level-gz-backup.log | \
		tee ${RLOG}
	echo
}

# File Level Backup using restic
file-level-backup () {
	SNAPSHOT_MOUNTPOINT="/mnt/${SNAPSHOT_NAME}"

	# Create the snapshot mount directory
	if [ ! -d ${SNAPSHOT_MOUNTPOINT} ] ; then
	mkdir ${SNAPSHOT_MOUNTPOINT}
	fi

	# Protect the snapshot mount-point
	chmod go-rwx ${SNAPSHOT_MOUNTPOINT}

	# Mount the snapshot read-only
	mount -o ro ${SNAPSHOT_PATH} ${SNAPSHOT_MOUNTPOINT}

	# Check free Space on volume
	DF=$(df -hlP ${SNAPSHOT_MOUNTPOINT} | awk 'int($5)>80{print "Volume "$1" has only "$4" free space left."}')

	restic \
		--verbose \
		--tag LV \
		--tag file-level-backup \
		--tag ${LV_TO_BACKUP} \
		--tag ${BACKUP_LV_SIZE}g_size \
		backup ${SNAPSHOT_MOUNTPOINT} \
		--exclude-file="${RESTIC_EXCLUDE}" | \
		tee -a ${LOGDIR}/lvm-restic-file-level-backup.log | \
		tee ${RLOG}

    # Unmount the Snapshot & Delete the mount-point
	umount ${SNAPSHOT_MOUNTPOINT}
	rmdir ${SNAPSHOT_MOUNTPOINT}
}

snap-and-back () {
	echo
	cecho $blue "======================================================="
	cecho $blue "Starting backup of LV $BACKUP_LV"
	echo
	sleep 5

	# Get the Path + Size of the LV to Backup
	BACKUP_LV_PATH=$(lvs --noheading -o lv_path | grep -P "/${BACKUP_LV}( |$)" | tr -d '  ')
	BACKUP_LV_SIZE=$(lvs ${BACKUP_LV_PATH} -o LV_SIZE --noheadings --units g --nosuffix)
	SNAPSHOT_NAME="${BACKUP_LV}_snapshot"
	SNAPSHOT_PATH="${BACKUP_LV_PATH}_snapshot"

	# Check if LV does exist
	if [ ! ${BACKUP_LV_PATH} ]
	then
	    echo "[Error] Cannot find path for ${BACKUP_LV}"
	    failed
	    exit 1
	fi

	# Check for old snapshots
	clean-snapshot

	# Create the snapshot
	lvcreate --quiet -L${LVM_SNAPSHOT_BUFFER} -s -n ${SNAPSHOT_NAME} ${BACKUP_LV_PATH} > /dev/null

	eval $cmd

	lvremove -f ${SNAPSHOT_PATH} > /dev/null

	log-backup
}

backup () {
	zabbix-requirements
	zabbix-discovery

	if [ "${LV_TO_BACKUP}" ] 
	then
		if [ -f "${LV_TO_BACKUP}" ] 
		then
			echo "[INFO] Verifying that all listed LV exist"
			grep -v '^#' ${LV_TO_BACKUP} | while read -r line
			do
				lvs --noheading -o lv_path | grep -P "/$line( |$)" || missing=true
				#if (lvs --noheading -o lv_path | grep -P "/$line( |$)")
			done

			# If any LV is missing, exit now
			if [ "$missing" = true ]; then echo "Not all LVs listed exist." && failed; fi

			# Read the file provided and backup each LV
			grep -v '^#' ${LV_TO_BACKUP} | while read -r line
			do
				BACKUP_LV=$line
				snap-and-back
			done
		else
			# Backup LV provided
			BACKUP_LV=${LV_TO_BACKUP}
			snap-and-back
		fi
	else
		echo "LV(s) to backup missing. Please specify [lv-name] or [path-to-list]."
		echo "Run [lvm-rescript help] for usage."
		exit 1
	fi
}

# -------------------------------------------------------
#   The restore task
# -------------------------------------------------------

restore-lv () {
	echo
	echo "*** RESTORE ***"

	# Check provided volume group
	if [ ! ${VG} ]
	then
	    echo "[Error] Volume Group must be specified"
	    failed
	    exit 1
	fi

	restore_size=$(restic ls --json --path /${RESTORE_LV}.img.gz latest / | jq '.tags' | grep -o '[0-9]*,[0-9]*g')
	restore_size_int=$( echo ${restore_size//,/.} | python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))')
	
	echo "[INFO] LV Name: ${RESTORE_LV}"
	echo "[INFO] LV Size: ${restore_size}"

	RESTORE_LV_PATH=$(lvs --noheading -o lv_path | grep -P "/${RESTORE_LV}( |$)" | tr -d '  ')
	RESTORE_LV_SIZE=$(lvs ${RESTORE_LV_PATH} -o LV_SIZE --noheadings --units g --nosuffix)

	if [ "${RESTORE_LV_PATH}" ] # Is there any LV with the same name?
	then
		# https://stackoverflow.com/questions/1885525/how-do-i-prompt-a-user-for-confirmation-in-bash-script
		echo
		echo "There is already an LV with the same name in ${RESTORE_LV_PATH}"
		echo "The size of the existing LV is ${RESTORE_LV_SIZE},"
		echo "the size of the LV to restore is ${restore_size}"
		read -p "Do you want to use the existing LV? (y/n)" -n 1 -r
		echo    # (optional) move to a new line
		if [[ $REPLY =~ ^[Yy]$ ]]
		then
		    echo "ok"
		else
			echo "Please rename/remove the LV ${RESTORE_LV} manually!"
			failed
			exit
		fi
	else
		echo "[INFO] Creating LV ${RESTORE_LV}, ${restore_size} on ${VG}"
		sleep 2
		lvcreate -n ${RESTORE_LV} -L ${restore_size} ${VG}
	fi

	RESTORE_LV_PATH=$(lvs --noheading -o lv_path | grep -P "/${RESTORE_LV}( |$)" | tr -d '  ')
	echo "[INFO] Starting Restore of ${RESTORE_LV}"
	sleep 2
	restic dump --path /${RESTORE_LV}.img.gz latest ${RESTORE_LV}.img.gz | \
		unpigz | pv -s ${restore_size_int} | \
		dd of=${RESTORE_LV_PATH} bs=4M
}

select-vg () {
	echo
	cecho $pink "Please select one of the following Volume Group(s):"
	select vg in $(vgs --noheading -o vg_name | tr -d '  ')
	do
		[ $vg ] && break
	done
	echo
}

restore () {
	if [ "${LV_TO_RESTORE}" ]
	then
		select-vg
		if [ -f "${LV_TO_RESTORE}" ] 
		then
			# Read the file provided and backup each LV
			grep -v '^#' ${LV_TO_RESTORE} | while read -r line
			do
				RESTORE_LV=$line
				restore-lv
			done
		else
			# Backup LV provided
			RESTORE_LV=${LV_TO_RESTORE}
			restore-lv
		fi
	else
		echo "LV(s) to restore missing. Please specify [lv-name] or [path-to-list]."
		echo "Run [lvm-rescript help] for usage."
		exit 1
	fi
}

zabbix-requirements () {
	skip_zabbix=false
	if ! `systemctl is-active --quiet zabbix-agent`
	then
		echo
		cecho $red "Zabbix-Agent is not running. Will skip zabbix logging."
		skip_zabbix=true
	fi
	if ! `command -v pip3 >/dev/null 2>&1`
	then
		cecho $red "Please install python3-pip."
		skip_zabbix=true
	fi
	if ! `python3 -c 'import humanfriendly' >/dev/null 2>&1`
	then
		cecho $red "Could not import python3 humanfriendly!"
		cecho $red "Please run 'pip3 install humanfriendly'."
		skip_zabbix=true
	fi
	if [ ! -f "/etc/zabbix/scripts/rescript-lvm-discovery.pl" ]
	then
		echo
		cecho $red "Zabbix Script rescript-lvm-discovery.pl missing. For instructions visit:"
		cecho $red "https://github.com/sebastian13/zabbix-templates/tree/master/rescript-restic-backup"
		skip_zabbix=true
	fi
	echo
}

zabbix-discovery () {
	if [ $skip_zabbix = false ]
	then
		cecho $yellow "[Running Zabbix Discovery]"
		export REPO="$repo"
		export LV_TO_BACKUP="$LV_TO_BACKUP"
		LVM_DISC=$(/etc/zabbix/scripts/rescript-lvm-discovery.pl)
		echo "$LVM_DISC" | python -m json.tool
		echo
		zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --key "rescript.lv.discovery" --value "$LVM_DISC"
		echo
	else
		cecho $red "[Skipping Zabbix Discovery]"
	fi
}

log-backup () {
	if [ $skip_zabbix = false ]
	then
		arr=()
		TIME=$(stat -c '%015Y' $RLOG)

		# Extract Added Bytes
		RLOG_ADDED=$(cat $RLOG | grep 'Added to the repo' | awk '{print $5,$6}' | \
			python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))' )
		arr+=("- restic.backup.added.[$BACKUP_LV.$REPO] $TIME $RLOG_ADDED")
		echo "Bytes Added:      $RLOG_ADDED"

		# Exctract Snapshot ID
		RLOG_SNAPSHOTID=$(cat $RLOG | grep '^snapshot .* saved$' | awk '{print $2}')
		arr+=("- restic.backup.snapshotid.[$BACKUP_LV.$REPO] $TIME $RLOG_SNAPSHOTID")
		echo "Snapshot ID:      $RLOG_SNAPSHOTID"

		# Extract Processed Time
		RLOG_PROCESSED_TIME=$(cat $RLOG | grep '^processed.*files' | \
				    awk '{print $NF}' | \
				    awk -F':' '{print (NF>2 ? $(NF-2)*3600 : 0) + (NF>1 ? $(NF-1)*60 : 0) + $(NF)}' )
		arr+=("- restic.backup.processedtime.[$BACKUP_LV.$REPO] $TIME $RLOG_PROCESSED_TIME")
		echo "Time Processed:   $RLOG_PROCESSED_TIME"

		# Extract Processed Bytes
		RLOG_PROCESSED_BYTES=$(cat $RLOG | grep '^processed.*files' | \
				     awk '{print $4,$5}' | \
				     python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))'  )
		arr+=("- restic.backup.processedbytes.[$BACKUP_LV.$REPO] $TIME $RLOG_PROCESSED_BYTES")
		echo "Bytes Processed:  $RLOG_PROCESSED_TIME"  

		cecho $yellow "[Sending everything to Zabbix]"
		# for ix in ${!arr[*]}; do printf "%s\n" "${arr[$ix]}"; done
		# echo
		send-to-zabbix () {
			for ix in ${!arr[*]}; do printf "%s\n" "${arr[$ix]}"; done | zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --with-timestamps --input-file -
		}

		# Send Data
		# It might be the case that the Zabbix Server has not fully processed the discovery of new items yet.
		# If sending raises an error, the script starts a second try after one minute.
		send-to-zabbix || { cecho $red "[ERROR] Sending or processing of some items failed. Will wait one minute before trying again..."; sleep 60; send-to-zabbix; }
		echo
	else
		cecho $red "[Skipping Sending Data to Zabbix]"
	fi
}

# -------------------------------------------------------
#   Run Selected Commands
# -------------------------------------------------------
cmd="$2"
case "$cmd" in
	"")
		echo "Please specify a command."
		echo "Run [lvm-rescript help] for usage."
		exit 1
		;;
	block-level-backup|block-level-gz-backup|file-level-backup)
		LV_TO_BACKUP=$3
		backup
		;;
	restore)
		echo "restore selected"
		LV_TO_RESTORE=$3
		restore
		;;
	*)
		echo "Unknown Command: ${cmd}."
		echo "Run [lvm-rescript help] for usage."
		exit 1
		;;
esac

# Remove temp. logfile
rm $RLOG

# Remove all remaining snapshots
clean-all-snapshots
all-done
