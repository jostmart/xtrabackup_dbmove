#!/bin/bash

#
# Remember to use the -i option for extracting a tarred backup
#

ulimit -n 65536
dt=`date '+%d-%m-%Y_%H-%M-%S'`

exec 1> >(logger -s -t $(basename $0)) 2>&1

####################################################
# Stuff you need to change                         #
####################################################
# TGT_SRV Where the backup will be transfered to.
# You need to setup ssh-keys on the target host.
TGT_SRV=192.168.1.105

# Where to put the files on the source server
TGT_DIR=/root/backups

# MySQL/MariaDB default group. 
# Look inside your mysql configuration file
defgroup='mysqld'

# There are a couple of different packages containing xtrabackup
xtrabackup_package="percona-xtrabackup-24"

# Which database to connect against
socket=/var/run/mysqld/mysqld.sock

# Set to false if we should use a directory on localhost (configured in TGT_SRV)
# Setting this to true mean: TGT_SRV is another server
streaming=true
####################################################

echo "---[ Database export start ]--------------------------"

# If we want to create the databasedump on localhost, 
# we can check for the directory TGT_DIR
if [ $streaming == false ]; then
  if [ ! -d $TGT_DIR ]; then
    echo "Target directory ${TGT_DIR} does not exist"

    while true; do
      read -p "Do you want me to create ${TGT_DIR}?" yn
      case $yn in
          [Yy]* ) mkdir ${TGT_DIR}; break;;
          [Nn]* ) exit;;
          * ) echo "Please answer yes or no.";;
      esac
    done
  fi

else
    echo "Streaming backup to server ${TGT_SRV}"
    echo "Checking SSH-key setup to ${TGT_SRV}"
    # Perfect place, to place a check on the ssh-connection
    status=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@$TGT_SRV echo ok 2>&1)

    if [[ $status == ok ]] ; then
      echo "SSH access check: OK"

      ssh $TGT_SRV mkdir ${TGT_DIR}/${dt}
      echo "Backup files will be placed in ${TGT_SRV}:${TGT_DIR}/${dt}"
     
    elif [[ $status == "Permission denied"* ]] ; then
      echo "SSH access check: NOT OK"
      exit
    else
      echo "SSH access check: Misc access error. Check auth.log"
      exit
    fi

fi

# Check for the innobackupex command
# If it's not there, we are missing the xtrabackup package
innobex=`which innobackupex`
if [ $? -ne 0 ]; then 
  while true; do
    read -p "Do you want me to install xtrabackup_package" yn
    case $yn in
        [Yy]* ) 
  	  apt-get install ${xtrabackup_package} -y --allow-unauthenticated
          break;;
        [Nn]* ) exit;;
        * ) echo "Please answer yes or no.";;
    esac
  done

  innobex=`which innobackupex`
fi

cat=`which cat`

# Check if dialog is installed and install it if not
dia=`which dialog`
if [ "$?" -ne 0 ]; then
  apt-get install dialog -y
  dia=`which dialog`
fi



# Create a list of databases, that we display in Dialog
databases=`mysql -N --socket=${socket} -e 'show databases' | egrep -v "information_schema|performance_schema|mysql" | tr '\n' ' '`

# Build array of the databases for Dialog to display
for database in $databases ; do
  options+=($database "(Copy)" off)
done

cmd=(dialog --separate-output --checklist "Select options:" 22 76 16)
choices=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
clear

# Format the output to suite innobackupex
# That is, from array to string
for choice in $choices
do
    dbs_to_dump=$dbs_to_dump"${choice} "
done


if [ $streaming == true ]; then

  # Create a list of choosen databases.
  echo $dbs_to_dump > /tmp/databases_${dt}.txt
  scp /tmp/databases_${dt}.txt ${TGT_SRV}:${TGT_DIR}/${dt}/
  rm /tmp/databases_${dt}.txt

#  echo "$innobex --export --no-lock --stream=xbstream --tmpdir=/tmp --parallel=4 --databases=\"${dbs_to_dump}\" --defaults-group=${defgroup} | ssh root@${TGT_SRV} \"xbstream --directory=${TGT_DIR}/${dt} -x\""

  $innobex --export --no-lock --stream=xbstream --tmpdir=/tmp --parallel=4 --databases="${dbs_to_dump}" --defaults-group=${defgroup} ./ | ssh root@${TGT_SRV} "xbstream --directory=${TGT_DIR}/${dt} -x"

else
  # Create a list of choosen databases.
  echo $dbs_to_dump > ${TGT_DIR}/databases_${dt}.txt

  # We dont want to stream to another server
  # echo "$innobex --databases=\"${dbs_to_dump}\" --defaults-group=${defgroup} ${TGT_DIR}/"
  $innobex --export --no-lock --databases="${dbs_to_dump}" --defaults-group=${defgroup} ${TGT_DIR}/
fi 

echo "---[ Database export end ]--------------------------"
exit 0
