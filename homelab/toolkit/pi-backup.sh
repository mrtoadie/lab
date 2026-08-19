#!/bin/bash

RPI_IPS=("192.168.178.210" "192.168.178.212" "192.168.178.214" "192.168.178.216")

# Logdate & file
LOGDATE=$(date +%b.%d.%Y_%H.%M)
ATT=/home/toadie/Dokumente/Obsidian/Linux/Logs/Cluster_"$HOSTNAME"_"$LOGDATE".md
# Date & Notify Icon
DATE=$(date "+%d.%m.%Y %H:%M")
ICON="/run/media/toadie/data/Dev/Bash/AlienHand8080.jpg"
# Paths
REMOTE_USER="toadie"
REMOTE_HOST="192.168.178.210"
REMOTE_PATH="/home/toadie"
REMOTE_DATA_PATH="/media/toadie/clusterdata"

LOCAL_BACKUP_DIR="/home/toadie/Projekte/"

# Color  Variables
green='\e[32m'
blue='\e[34m'
red='\e[1;31m'
clear='\e[0m'
#############################

# Markdown / Obsidian 'file header'
function index
{
    echo "---" >> $ATT
    echo "tags:" >> $ATT
    echo "- Backup" >> $ATT
    echo "- Log" >> $ATT
    echo "---" >> $ATT

    echo "# Rsync Backup01" $LOGDATE - $LOGTIME "Uhr" >> $ATT
}


function nfs-data {
  rsync -avz -e ssh toadie@192.168.178.210:$REMOTE_DATA_PATH /home/toadie/Projekte/	
}


function test {
  for i in "${!RPI_IPS[@]}"; do
    IP="${RPI_IPS[$i]}"
    HOSTNAME="rpi$(($i + 1))"
    
    #echo "=== Backup rpi$((i + 1)): ${IP} ==="
    figlet -f small BACKUP $REMOTE_HOSTNAME
        
        echo "##" $REMOTE_HOST >> $ATT
        echo -e "${blue}================================================================"
        echo -e "["$i"]" "["$REMOTE_HOST"]"
        echo -e "================================================================${clear}"
    rsync -avz --progress --stats -e ssh \
      --exclude='.cache/go-build' \
      --exclude='.cache/gocode' \
      --exclude='go' \
      --exclude='Music' \
      --exclude='/proc' \
      --exclude='/sys' \
      --exclude='/tmp' \
      --exclude='/dev' \
      --exclude='.local/share/Trash' \
      "${REMOTE_USER}@${IP}:/home/toadie/" \
      "${LOCAL_BACKUP_DIR}/${HOSTNAME}/" \
      --delete-during -r --log-file=$ATT

      echo "" >> $ATT
      echo "---" >> $ATT    
done
}

index
test
nfs-data
