#!/usr/bin/env bash
function backup
{
	# backup
	msg "Initialization completed. \n"
	for target_path in `find /home -mindepth 1 -maxdepth 1 -type d`; do
		_backupFile $target_path
	done
	_backupFile /var/log
	_backupMysql
	
	# check
	if [[ ! -d $dir_backup_file && ! -d $dir_backup_mysql ]]; then
		msg "\e[31mBackup failed!\e[0m \n"
		return
	fi
	
	# upload to remote storage
	msg "Uploading to remote storage \n"
	rclone copy $dir_storage $rclone_remote_prefix --progress --transfers 1 --buffer-size 0M
	
	# update timestamps of working directories for prevent deleted
	find $dir_storage/$date_month -type d | xargs -r touch
	
	# delete expired backup files on local storage
	find $dir_storage -mindepth 1 -mtime +$local_expire_days | xargs -r rm -rf
	
	# delete expired backup files on remote storage
	if [[ -d $dir_snap/$date_expire_month ]]; then
		msg "Deleting expired backup files on remote storage \n"
		rclone delete $rclone_remote_prefix/$date_expire_month --progress > /dev/null 2>&1
		rm -rf $dir_snap/$date_expire_month
	fi
	
	# end
	msg "Backup completed! \n"
}

function restore
{
	local _local_path=$1
	local _remote_path=$2
	local _restore_path=$_local_path/restore
	
	# get backup files from remote storage
	if [[ -n $_remote_path ]]; then
		if compgen -G "$_local_path/*" > /dev/null; then
			echo -e "\e[31mWarning: Existing files in the target path will be deleted if continue.\e[0m"
			read -p "Y/n> " _whether
			if [[ $_whether != "Y" ]]; then
				return
			fi
		fi
		msg "Getting backup files from remote storage. \n"
		rm -rf $_local_path && mkdir -p $_local_path
		rclone copy $rclone_remote_prefix$_remote_path $_local_path --progress
	fi
	
	# check
	local _backup_files=`find $_local_path -maxdepth 1 -type f -name "*.tgz" | sort`
	if [[ -z $_backup_files ]]; then
		msg "\e[31mtgz backup files not exists in the target path\e[0m \n"
		return
	elif [[ -n $_remote_path ]]; then
		msg "Download completed! \n"
	fi
	rm -rf $_restore_path && mkdir -p $_restore_path
	
	# restoring
	msg "Restoring ... \n"
	for tgz_file in $_backup_files; do
		tar -zxGf $tgz_file -C $_restore_path
	done
	
	# end
	msg "Restore completed! \n"
}

function _backupFile
{
	local _dir_file=$dir_backup_file/$1
	local _dir_snap=$dir_snap/$date_month/$1
	local _file_snap=$_dir_snap/$date_time.snap
	local _backup_file_name=${1//\//.}
	_backup_file_name=${_backup_file_name:1}
	
	# check already snap
	if [[ -f $_file_snap ]]; then
		msg "Skipping already exist backup of $1 \n"
		return
	fi
	
	# making snap directory
	if [[ ! -d $_dir_snap ]]; then
		mkdir -p $_dir_snap
		local _base=".base"
	# copy previous snap
	else
		local _previous_snap=`find $_dir_snap -maxdepth 1 -type f -name "*.snap" | sort | tail -n 1`
		if [[ -n $_previous_snap ]]; then
			cp $_previous_snap $_file_snap
		else
			local _base=".base"
		fi
	fi
	
	# making file directory
	mkdir -p $_dir_file
	
	# packing
	msg "Packing file $1 ..."
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
	
	msg "completed"
}

function _backupMysql
{
	if [[ $mysql_auth_type == "password" ]]; then
		mysql_auth_option="-h $mysql_host -u $mysql_user -p$mysql_password"
	fi
	
	# get database lists
	local _database_list=`mysql $mysql_auth_option -e "SHOW DATABASES;" --skip-column-names | grep -Ev "(information_schema|performance_schema|mysql|phpmyadmin)"`
	if [[ $? != 0 ]]; then
		msg "\e[31mCannot access or no database\e[0m \n"
		return
	fi
	
	for database_name in $_database_list; do
		local _dir_database=$dir_backup_mysql/$database_name
		
		# making database directory
		mkdir -p $_dir_database
		
		# exporting
		msg "Exporting $database_name database to file ..."
		mysqldump $mysql_auth_option --opt --single-transaction -e $database_name | gzip > $_dir_database/$database_name.$date_time.sql.gz
		msg "completed"
	done
}

function msg
{
	if [[ $1 == "completed" ]]; then
		echo -e "\e[32m completed \e[0m"
	elif [[ $1 == "failed" ]]; then
		echo -e "\e[31m failed \e[0m"
	else
		echo -ne "\e[33m$1\e[0m"
	fi
}


msg "Let's backup! script ver 1.2.0 \n"

command=${*:$OPTIND:1}
arg1=${*:$OPTIND+1:1}
arg2=${*:$OPTIND+2:1}
let argnum=$#-$OPTIND

config_path=~/.config/letsbackup
config_file=$config_path/letsbackup.conf
if [[ ! -f $config_file || $command == "config" ]]; then
	cat <<EOF
Proceed with the initial setup required for execution.

Select the type of mysql authentication that will be used for mysql backup.
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
		read -e -p "mysql user: " -i "root" mysql_user
		read -s -p "mysql password: " mysql_password
		echo ""
		if [[ -z $mysql_user ]]; then
			echo -e "\e[31mThere is no input.\e[0m"
			exit
		fi
		mysql_auth_option="-h localhost -u $mysql_user -p$mysql_password"
	fi
	if ! mysql $mysql_auth_option -e ""; then
		echo -e "\e[31mmysql authentication failed.\e[0m"
		exit
	fi
	echo ""
	cat <<EOF
Enter the remote name of rclone config that will be used for remote backup.
Important: Must be the same "remote name of rclone config" and "bucket name of remote storage"
EOF
	read -p "string> " rclone_remote_name
	if [[ -z $rclone_remote_name ]]; then
		echo -e "\e[31m\nThere is no input.\e[0m"
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

# set date
date_month=`date +%Y%m`
date_time=`date +%Y%m%d%H%M%S`
date_expire_month=`date +%Y%m -d "$remote_expire_months month ago"`

# set directory
mkdir -p $letsbackup_path && chmod 700 $letsbackup_path
dir_storage=$letsbackup_path/storage
dir_snap=$letsbackup_path/snap
dir_backup_file=$dir_storage/$date_month/file
dir_backup_mysql=$dir_storage/$date_month/mysql

# set parameters
case $command in
	backup)
		backup
	;;
	restore)
		if [[ $argnum -lt 1 ]]; then
			echo -e "path to tgz backup files is not set."
			exit 1
		fi
		restore $arg1 $arg2
	;;
esac
