#!/usr/bin/env bash
function backup
{
	echo -e "\e[33mStart backup.\e[0m"
	for _target_path in `find /home -mindepth 1 -maxdepth 1 -type d`; do
		_backupFile $_target_path
	done
	_backupFile /var/log
	_backupMysql
	
	# Check if the backup was successful
	if [[ ! -d $dir_backup_file && ! -d $dir_backup_mysql ]]; then
		echo -e "\e[31mBackup failed.\e[0m"
		return
	fi
	
	# Uploading to remote storage...
	echo -e "\e[33mUploading to remote storage...\e[0m"
	rclone copy $dir_storage $rclone_remote_prefix --progress --transfers 1 --buffer-size 0M
	
	# Update timestamps of working directories for prevent deleted
	find $dir_storage/$date_month -type d | xargs -r touch
	
	# Delete expired backup files on local storage
	find $dir_storage -mindepth 1 -mtime +$local_expire_days | xargs -r rm -rf
	
	# Deleting expired backup files on remote storage...
	if [[ -d $dir_snap/$date_expire_month ]]; then
		echo -e "\e[33mDeleting expired backup files on remote storage...\e[0m"
		rclone delete $rclone_remote_prefix/$date_expire_month --progress > /dev/null 2>&1
		rm -rf $dir_snap/$date_expire_month
	fi
	
	echo -e "\e[33mCompleted.\e[0m"
}

function restore
{
	local _local_path=$1
	local _remote_path=$2
	local _restore_path=$_local_path/restore
	
	# Downloading backup files from remote storage...
	if [[ -n $_remote_path ]]; then
		if compgen -G "$_local_path/*" > /dev/null; then
			echo -e "\e[31mWarning: If you continue, existing files in the local path will be deleted.\e[0m"
			read -p "Y/n> " _whether
			if [[ $_whether != "Y" ]]; then
				return
			fi
		fi
		echo -e "\e[33mDownloading backup files from remote storage...\e[0m"
		rm -rf $_local_path && mkdir -p $_local_path
		rclone copy $rclone_remote_prefix$_remote_path $_local_path --progress
	fi
	
	# Check if backup files exist
	local _backup_files=`find $_local_path -maxdepth 1 -type f -name "*.tgz" | sort`
	if [[ -z $_backup_files ]]; then
		echo -e "\e[31mNo backup files in the local path.\e[0m"
		return
	fi
	rm -rf $_restore_path && mkdir -p $_restore_path
	
	# Restoring...
	echo -e "\e[33mRestoring...\e[0m"
	for _tgz_file in $_backup_files; do
		echo "Unpacking $(basename $_tgz_file)"
		tar -zxGf $_tgz_file -C $_restore_path
	done
	
	echo -e "\e[33mCompleted.\e[0m"
}

function _backupFile
{
	local _dir_file=$dir_backup_file/$1
	local _dir_snap=$dir_snap/$date_month/$1
	local _file_snap=$_dir_snap/$date_time.snap
	local _backup_file_name=${1//\//.}
	_backup_file_name=${_backup_file_name:1}
	
	# Check if the snap file already exists
	if [[ -f $_file_snap ]]; then
		echo "Already backuped $1 skipped."
		return
	fi
	
	# Create the snap directory
	if [[ ! -d $_dir_snap ]]; then
		mkdir -p $_dir_snap
		local _base=".base"
	# Copy the previous snap file for incremental backup
	else
		local _previous_snap=`find $_dir_snap -maxdepth 1 -type f -name "*.snap" | sort | tail -n 1`
		if [[ -n $_previous_snap ]]; then
			cp $_previous_snap $_file_snap
		else
			local _base=".base"
		fi
	fi
	
	# Create the file directory
	mkdir -p $_dir_file
	
	# Packing the path ...
	echo -en "\e[33mPacking $1 ...\e[0m"
	tar -g $_file_snap -zcf $_dir_file/$_backup_file_name.$date_time$_base.tgz --atime-preserve=system \
		--exclude=$letsbackup_path \
		--exclude=files/attach/chunks \
		--exclude=files/cache \
		--exclude=files/debug \
		--exclude=files/supercache \
		--exclude=files/thumbnails \
		--exclude=files/member_extra_info/experience \
		--exclude=files/member_extra_info/new_message_flags \
		--exclude=files/member_extra_info/point \
		--exclude=files/tmp \
	$1 > /dev/null 2>&1
	echo -e "\e[32m Completed \e[0m"
}

function _backupMysql
{
	if [[ $mysql_auth_type == "password" ]]; then
		mysql_auth_option="-h $mysql_host -u $mysql_user -p$mysql_password"
	fi
	
	# Get database list
	local _database_list=`mariadb $mysql_auth_option -e "SHOW DATABASES;" --skip-column-names | grep -Ev "(information_schema|performance_schema|mysql|phpmyadmin|sys)"`
	if [[ $? != 0 ]]; then
		echo "No databases or are inaccessible."
		return
	fi
	
	for _database_name in $_database_list; do
		local _dir_database=$dir_backup_mysql/$_database_name
		
		# Create the database directory
		mkdir -p $_dir_database
		
		# Exporting the database to file ...
		echo -en "\e[33mExporting $_database_name database to file ...\e[0m"
		mariadb-dump $mysql_auth_option --opt --single-transaction -e $_database_name | gzip > $_dir_database/$_database_name.$date_time.sql.gz
		echo -e "\e[32m Completed \e[0m"
	done
}



echo -e "\e[33mLet's Backup! script ver 1.2.0\e[0m"

command=${*:$OPTIND:1}
arg1=${*:$OPTIND+1:1}
arg2=${*:$OPTIND+2:1}
let argnum=$#-$OPTIND

config_path=~/.config/letsbackup
config_file=$config_path/letsbackup.conf
if [[ ! -f $config_file || $command == "config" ]]; then
	cat <<EOF
Proceed with the initial setup required for execution.

Select the type of MariaDB authentication that will be used for MariaDB backup.
1) unix socket (default)
2) password
EOF
	read -p "number> " mysql_auth_type
	case ${mysql_auth_type:-1} in
		1)
			mysql_auth_type="unix_socket"
			;;
		2)
			mysql_auth_type="password"
			;;
	esac
	if [[ $mysql_auth_type == "password" ]]; then
		echo ""
		read -e -p "MariaDB user: " -i "root" mysql_user
		read -s -p "MariaDB password: " mysql_password
		echo ""
		if [[ -z $mysql_user ]]; then
			echo "No input."
			exit
		fi
		mysql_auth_option="-h localhost -u $mysql_user -p$mysql_password"
	fi
	if ! mariadb $mysql_auth_option -e ""; then
		echo -e "\e[31mMariaDB authentication failed.\e[0m"
		exit
	fi
	echo ""
	cat <<EOF
Enter the remote name of rclone config that will be used for remote backup.
Important: Must be the same "remote name of rclone config" and "bucket name of remote storage"
EOF
	read -p "string> " rclone_remote_name
	if [[ -z $rclone_remote_name ]]; then
		echo "No input."
		exit
	fi
	if rclone lsf $rclone_remote_name:$rclone_remote_name > /dev/null 2>&1; then
		rclone_remote_prefix=$rclone_remote_name:$rclone_remote_name/backup
		rclone_remote_prefix_as='$rclone_remote_name:$rclone_remote_name/backup'
	else
		rclone_remote_prefix=$rclone_remote_name:backup
		rclone_remote_prefix_as='$rclone_remote_name:backup'
	fi
	echo ""
	cat <<EOF
Backup files stored on remote storage will be deleted after the number of months.
Press Enter for the default "12"
EOF
	read -p "number> " remote_expire_months
	echo ""
	cat <<EOF
Backup files stored on local storage will be deleted after the number of days.
Press Enter for the default "3"
EOF
	read -p "number> " local_expire_days
	echo ""
	mkdir -p $config_path
	cat <<EOF > $config_file
mysql_auth_type='$mysql_auth_type'
mysql_host='localhost'
mysql_user='${mysql_user//\'/\'\\\'\'}'
mysql_password='${mysql_password//\'/\'\\\'\'}'
rclone_remote_name='${rclone_remote_name//\'/\'\\\'\'}'
rclone_remote_prefix=$rclone_remote_prefix_as
remote_expire_months=${remote_expire_months:-12}
local_expire_days=${local_expire_days:-3}
letsbackup_path=~/.letsbackup
EOF
	chmod 0600 $config_file
	echo "Done. Please run it again."
	exit
fi

. $config_file
((remote_expire_months++))
((local_expire_days--))

# Set date
date_month=`date +%Y%m`
date_time=`date +%Y%m%d%H%M%S`
date_expire_month=`date +%Y%m -d "$remote_expire_months month ago"`

# Set directory
mkdir -p $letsbackup_path && chmod 700 $letsbackup_path
dir_storage=$letsbackup_path/storage
dir_snap=$letsbackup_path/snap
dir_backup_file=$dir_storage/$date_month/file
dir_backup_mysql=$dir_storage/$date_month/mysql

# Set parameters
case $command in
	backup)
		backup
	;;
	restore)
		if [[ $argnum -lt 1 ]]; then
			echo "No path parameter."
			exit 1
		fi
		restore $arg1 $arg2
	;;
esac
