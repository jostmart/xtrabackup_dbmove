# xtrabackup_dbmove

Used to import and export databases on the fly, with xtrabackup and mysqlfrm

## Installation
You need to setup the following:
- Passwordless ssh-keys if you will export databases to another server.
- Test SSH acces manually 
- Package repo configuration to be able to install xtrabackup
- .my.cnf for the root user



### Package repo configuration

Example for Ubuntu Xenial

```
apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xF1656F24C74CD1D8
add-apt-repository 'deb [arch=amd64,i386,ppc64el] http://ftp.ddg.lth.se/mariadb/repo/10.1/ubuntu xenial main'
apt-get update
```

### Installation of Xtrabackup package
```
apt-get install percona-xtrabackup-24
```

### Installation of passwordless ssh-keys
```
ssh-keygen
ssh-copy-id <target_server>
ssh <target_server> 
```
