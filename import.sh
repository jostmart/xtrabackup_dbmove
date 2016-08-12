#!/bin/bash

ulimit -n 65536

# All echo:s will be logged to syslog
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Gotta be root.
if [ $UID -ne 0 ]; then echo "Run this as root" ; exit ; fi

# Must send argument #1
if [ "$#" -ne 1 ]; then
  echo "Illegal number of parameters"
  exit 1
fi




####################################################
# Stuff you need to change                         #
####################################################

# Should point to where the backups should be created
# Check parameter TGT_DIR in the export script
# they should be set to the same directory
restore_dir=/srv/backups

# Change the datadir if needed to the mysql datadir.
# Should point to your mysql datadir
datadir=/var/lib/mysql

# mysqld port. 3306 is default mysqld port.
myport=3306

# The port to use for the spawned import server in the default mode. 
# Must be a free port.
mysqlfrmport=3310 

socket=/var/run/mysqld/mysqld.sock
username=root
password=password_for_username_above

# Make shure your package system have the packages you specify.
mysql_client_package=mariadb-client
xtrabackup_package="percona-xtrabackup"

####################################################
# End of configurables                             #
####################################################


# Check for the mysqlfrm command
which mysqlfrm > /dev/null 2>&1
if [ $? -ne 0 ]; then 
  echo "Installing package mysql-utilities"
  apt-get install mysql-utilities -y

  which mysqlfrm > /dev/null 2>&1
  if [ $? -ne 0 ]; then 
    echo "Installation of a mysql client failed. Please investigate"
    exit 1
  fi 

fi

# Check for the mysql client
which mysql > /dev/null 2>&1
if [ $? -ne 0 ]; then 
  echo "Installing package ${mysql_client_package}"
  apt-get install ${mysql_client_package} -y --allow-unauthenticated

  which mysql > /dev/null 2>&1
  if [ $? -ne 0 ]; then 
    echo "Installation of a mysql client failed. Please investigate"
    exit 1
  fi 
fi

# Check for the innobackupex command
# If it's not there, we are missing the xtrabackup package
which innobackupex > /dev/null 2>&1
if [ $? -ne 0 ]; then 
  apt-get install ${xtrabackup_package} -y --allow-unauthenticated

  which innobackupex > /dev/null 2>&1
  if [ $? -ne 0 ]; then 
    echo "Installation of ${xtrabackup_package} failed. Please investigate"
    exit 1
  fi 

fi

# Leave this line here
innobex=`which innobackupex`

#
# Check datadir for mysql install, figure mysql/user.frm should probably exist.
# We want to make sure there is a database server and that $datadir is correct
#
if [ ! -f $datadir/mysql/user.frm ] ; then echo "MySQL datadir not correct" ; exit ; fi

#
# Check if the server respond
#
/usr/bin/mysqladmin ping 2>/dev/null 1>/dev/null
if [ $? -ne 0 ]; then
  echo "The MySQL server process does not seem to be running, or authentication have failed"
  exit 1
fi


####################################################
## Find and extract the archive
####################################################

backup=$1
extract_dir=${restore_dir}/${backup}

if [ ! -d ${extract_dir} ]; then
  echo "Unable to find directory ${extract_dir}"
  exit 1
fi



#######
# Prepare the backup
######

echo "--[ Entering $extract_dir and running prepare ]"-----------------------
cd $extract_dir
$innobex --defaults-file=backup-my.cnf --apply-log --export .
echo "--[ Prepare step ready ]"----------------------------------------------


####################################################
## Import databases
####################################################


# Create a list of the databases from the dump
cd $extract_dir

databases=`ls -d */ | sed 's/\///' | egrep -v "mysql" | tr '\n' ' '`

# Build array of the databases for Dialog to display
for database in $databases ; do
  options+=($database "(Copy)" off)
done

cmd=(dialog --separate-output --checklist "Select options:" 22 76 16)
choices=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
clear

databases=$choices

echo "Going to import databases: $databases"

for database in $databases; do

  echo "Entering ${extract_dir}/${database}"
  cd ${extract_dir}/${database}

  # there need to be a file: db.opt
  if [ ! -f db.opt ] ; then echo "Restore directory invalid, couldn't find db.opt in it"; exit ; fi

  stoperror=0
  for restorename in *.frm
  do
      chkname=$(echo $restorename|sed s/.frm$//)
      for exten in cfg exp ibd
      do
          if [ ! -f $chkname.$exten ] ; then stoperror=1 ; fi
      done
  done

done


if [ $stoperror -eq 1 ] ; then
    echo "$chkname.exten"
    echo "Could not file valid restore directory files (need a cfg, exp and ibd for each frm)"
    echo "Did you specify a valid database directory within a backup?"
    echo "Did you prepare or apply-log to the backup directory?"
    exit 1
fi


echo "--[ Nuke and re-create the databases: $databases ]-------"
sleep 10

for database in $databases; do
 echo "mysql --port=$myport --socket=$socket -B -e \"DROP DATABASE IF EXISTS $database\""
 mysql --port=$myport --socket=$socket -B -e "DROP DATABASE IF EXISTS $database"
 if [ ! $? -eq 0 ]; then
   echo "Unable to drop database: $database"
   echo "Database import aborted. Check if there are orphan files in the /var/lib/mysql/$database/ directory."
   exit 1
 fi
 mysql --port=$myport --socket=$socket -B -e "CREATE DATABASE $database"
done




echo "--[ Moving on to mysqlfrm part, importing into empty databases ]-------"

for database in $databases; do
  echo "--[ $database ]--------"
  cd ${extract_dir}/${database}

  for table in $( ls *.frm ); do
    echo "mysqlfrm -q --user=root --server=$username:$password@localhost:$myport --port=$mysqlfrmport $table |"
    echo "mysql $database -B --port=$myport --socket=$socket"

    mysqlfrm -q --user=root --server=$username:$password@localhost:$myport --port=$mysqlfrmport $table |
      sed 's/WARNING: Using a password on the command line interface can be insecure.//' | 
      mysql $database -B --port=$myport --socket=$socket
    echo "Table structure $table for database $database imported."

    # set FOREIGN_KEY_CHECKS=0;

    echo "ALTER TABLE ... DISCARD TABLESPACE - junks those pesky datafiles we don't want."

    suffix=".frm"
    tablename=${table%$suffix}
    mysql $database -B --port=$myport --socket=$socket -e "ALTER TABLE ${tablename} DISCARD TABLESPACE"


    for exten in exp ibd; do
      rsync --progress $extract_dir/$database/$tablename.$exten $datadir/$database/$tablename.$exten
      chown $(find $datadir/$database/$tablename.frm -printf "%u.%g") $datadir/$database/$tablename.$exten
    done

    echo "  Importing tablespace for $tablename  "
    mysql $database -B --port=$myport --socket=$socket -e "ALTER TABLE $tablename IMPORT TABLESPACE"
    rm "$datadir/$database/${tablename}.exp"

  done


done




echo "Done"
exit 0
