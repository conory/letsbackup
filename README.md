# Let's Backup!
web service backup script using tar incremental and rclone for remote backup.

support backup for /home, /var/log directory and MYSQL DB.

## Configure
top line of letsbackup.sh.
- DB_HOST
- DB_USER
- DB_PASSWORD
- REMOTE_BUCKET
- REMOTE_EXPIRE_MONTHS
- LOCAL_EXPIRE_DAYS

## Usage
1. install [rclone](https://github.com/ncw/rclone).
2. configure rclone and letsbackup.sh.
3. set execute permission to letsbackup.sh.
### backup
```
# letsbackup.sh backup
```
### restore
```
# letsbackup.sh restore [path with tgz backup files]
```
restored in '[path with tgz backup files] /restore' path.
### restore after get backup files at remote
```
# letsbackup.sh restore [download path] [remote path with tgz backup files]
```
restored in '[download path] /restore' path, if only exist tgz backup files in the remote path.

## License
MIT License

## Blog
https://conory.com/ (korean)
