#!/usr/bin/env bash
# set variables
DB_HOST='localhost'
DB_USER='root'
DB_PASSWORD='[Config - root DB password]'
REMOTE_BUCKET='[Config - rclone remote name]'
LETSBACKUP_DIR='~/.letsbackup'
BACKUP_EXPIRES_MONTHS=24
name_dir_file=file
name_dir_db=DB
((BACKUP_EXPIRES_MONTHS++))

# set date
date_month=`date +%Y%m`
date_time=`date +%Y%m%d%H%M%S`
date_expires_month=`date +%Y%m -d "$BACKUP_EXPIRES_MONTHS month ago"`

# set directory
dir_backuping=$LETSBACKUP_DIR/backuping
dir_snap=$LETSBACKUP_DIR/snap/$date_month
dir_file=$dir_backuping/$date_month/$name_dir_file
dir_db=$dir_backuping/$date_month/$name_dir_db

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
	local _dir_file=$dir_file/$1
	local _dir_snap=$dir_snap/$1
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
	2>&1 | grep -v "tar: Removing leading"
	
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
		local _dir_db=$dir_db/$db
		
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
	if [ -d $dir_backuping ]; then
		rm -rf $dir_backuping
	fi
	
	# backup
	msg "Initialization completed. \n"
	_backupFile home /home
	_backupFile log /var/log
	_backupDB
	
	if [ ! -d $dir_backuping ]; then
		msg "\e[31mBackup failed!\e[0m \n"
		return
	fi
	
	# upload to remote storage
	msg "Uploading to remote storage \n"
	rclone copy $dir_backuping $REMOTE_BUCKET:$REMOTE_BUCKET
	
	# delete expired backup at remote storage
	msg "Deleting expired backup at remote storage \n"
	rclone delete $REMOTE_BUCKET:$REMOTE_BUCKET/$date_expires_month
	rm -rf $LETSBACKUP_DIR/snap/$date_expires_month
	
	# remove backup at local
	msg "Removing backup at local ..."
	rm -rf $dir_backuping
	msg "completed"
	
	# end
	msg "Backup completed! \n"
}

function restore
{
	local backup_files=`find $1 -maxdepth 1 -type f -name '*.tgz' | sort`
	if [ -z "$backup_files" ]; then
		msg "\e[31mtgz backup files not exist in the path\e[0m \n"
		return
	fi
	if [ -d $1/restore ]; then
		msg "already exist restored files. \n"
		return
	fi
	mkdir -p $1/restore
	
	msg "Restoring ... \n"
	for tgz_file in $backup_files; do
		tar -zxGf $tgz_file -C $1/restore
	done
	
	# end
	msg "Restore completed! \n"
}

# set parameters
command="${*:$OPTIND:1}"
arg1="${*:$OPTIND+1:1}"
let argnum=$#-$OPTIND

# start
msg "Let's backup! script ver 0.3 \n"
case $command in
	backup)
		backup
	;;
	restore)
		if [ $argnum -lt 1 ]; then
			echo -e "path to tgz backup files is not set."
			exit 1
		fi
		restore $arg1
	;;
esac
