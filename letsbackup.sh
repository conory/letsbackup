#!/usr/bin/env bash
# set variables
DB_HOST='localhost'
DB_USER='root'
DB_PASSWORD='[Config - root DB password]'
REMOTE_BUCKET='[Config - rclone remote name]'
REMOTE_EXPIRE_MONTHS=12
LOCAL_EXPIRE_DAYS=3
LETSBACKUP_DIR=~/.letsbackup
name_dir_file=file
name_dir_db=DB
((REMOTE_EXPIRE_MONTHS++))
((LOCAL_EXPIRE_DAYS--))

# set date
date_month=`date +%Y%m`
date_time=`date +%Y%m%d%H%M%S`
date_expire_month=`date +%Y%m -d "$REMOTE_EXPIRE_MONTHS month ago"`

# set directory
dir_storage=$LETSBACKUP_DIR/storage
dir_snap=$LETSBACKUP_DIR/snap
dir_backup_file=$dir_storage/$date_month/$name_dir_file
dir_backup_db=$dir_storage/$date_month/$name_dir_db

function makeDirectory
{
	mkdir -p $1
	chmod 700 $1
}

function msg
{
	if [ "$1" = 'completed' ]; then
		echo -e "\e[32m completed \e[0m"
	elif [ "$1" = 'failed' ]; then
		echo -e "\e[31m failed \e[0m"
	else
		echo -ne "\e[33m$1\e[0m"
	fi
}

function _backupFile
{
	local _dir_file=$dir_backup_file/$1
	local _dir_snap=$dir_snap/$date_month/$1
	local _file_snap=$_dir_snap/$date_time.snap
	
	# check already snap
	if [ -f $_file_snap ]; then
		msg "Skipping already exist backup of $2 \n"
		return
	fi
	
	# making snap directory
	if [ ! -d $_dir_snap ]; then
		makeDirectory $_dir_snap
	# copy previous snap
	else
		local previous_snap=`find $_dir_snap -maxdepth 1 -type f -name '*.snap' | sort | tail -n 1`
		cp $previous_snap $_file_snap
	fi
	
	# making file directory
	makeDirectory $_dir_file
	
	# packing
	msg "Packing file $2 ..."
	tar -g $_file_snap -zcf $_dir_file/$1.$date_time.tgz $2 --atime-preserve=system \
		--exclude=$LETSBACKUP_DIR \
		--exclude=files/cache \
		--exclude=files/supercache \
		--exclude=files/thumbnails \
		--exclude=files/member_extra_info/experience \
		--exclude=files/member_extra_info/new_message_flags \
		--exclude=files/member_extra_info/point \
		--exclude=files/tmp \
	>/dev/null 2>&1
	
	msg 'completed'
}

function _backupDB
{
	# get DB lists
	db_list=`mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD -e "SHOW DATABASES;" --skip-column-names | grep -Ev "(information_schema|performance_schema)"`
	if [ $? != 0 ]; then
		msg "\e[31mCannot access database\e[0m \n"
		return
	fi
	
	for db in $db_list; do
		local _dir_db=$dir_backup_db/$db
		
		# making DB directory
		makeDirectory $_dir_db
		
		# exporting
		msg "Exporting $db database to file ..."
		mysqldump -h $DB_HOST -u $DB_USER -p$DB_PASSWORD --opt --single-transaction -e $db | gzip > "$_dir_db/$db.$date_time.sql.gz"
		if [ $? != 0 ]; then
			msg 'failed'
		else
			msg 'completed'
		fi
	done
}

function backup
{
	# backup
	msg "Initialization completed. \n"
	_backupFile home /home
	_backupFile log /var/log
	_backupDB
	
	# check
	if [ ! -d $dir_storage ]; then
		msg "\e[31mBackup failed!\e[0m \n"
		return
	fi
	
	# upload to remote storage
	msg "Uploading to remote storage \n"
	rclone copy $dir_storage $REMOTE_BUCKET:$REMOTE_BUCKET
	
	# delete expired backup at local
	find $dir_storage -mindepth 1 -mtime +$LOCAL_EXPIRE_DAYS | xargs rm -rf
	
	# delete expired backup at remote storage
	if [ -d $dir_snap/$date_expire_month ]; then
		msg "Deleting expired backup at remote storage \n"
		rclone delete $REMOTE_BUCKET:$REMOTE_BUCKET/$date_expire_month
		rm -rf $dir_snap/$date_expire_month
	fi
	
	# end
	msg "Backup completed! \n"
}

function restore
{
	local local_path="$1"
	local remote_path="$2"
	local restore_path=$local_path/restore
	
	# get backup files from remote storage
	if [ ! -z $remote_path ]; then
		msg "Getting backup files from remote storage. \n"
		rm -rf $local_path && mkdir -p $local_path
		rclone copy $REMOTE_BUCKET:$REMOTE_BUCKET/$remote_path $local_path
	fi
	
	# check
	local backup_files=`find $local_path -maxdepth 1 -type f -name '*.tgz' | sort`
	if [ -z "$backup_files" ]; then
		if [ ! -z $remote_path ]; then
			msg "Download completed! \n"
		else
			msg "\e[31mtgz backup files not exist in the path\e[0m \n"
		fi
		return
	fi
	rm -rf $restore_path && mkdir -p $restore_path
	
	# restoring
	msg "Restoring ... \n"
	for tgz_file in $backup_files; do
		tar -zxGf $tgz_file -C $restore_path
	done
	
	# end
	msg "Restore completed! \n"
}

# set parameters
command="${*:$OPTIND:1}"
arg1="${*:$OPTIND+1:1}"
arg2="${*:$OPTIND+2:1}"
let argnum=$#-$OPTIND

# start
msg "Let's backup! script ver 0.4 \n"
case $command in
	backup)
		backup
	;;
	restore)
		if [ $argnum -lt 1 ]; then
			echo -e "path to tgz backup files is not set."
			exit 1
		fi
		restore $arg1 $arg2
	;;
esac
