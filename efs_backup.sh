#!/bin/bash
# ver 0.1
# Igor David
# Oct 2017

SNS_TOPIC="arn:aws:sns:us-east-1:AWS_ACCOUNT_NUMBER:EFS_backup"
DATE=`date +%Y-%m-%d-%T`
YEAR=`date +%Y`
MONTH=`date +%m`
DAY=`date +%d`
TIME=`date +%T`
MOUNT_POINT="/media/efs_backup"
INST_REGION=`curl -s 169.254.169.254/latest/dynamic/instance-identity/document | grep region | xargs -l bash -c 'echo $2'| awk -F"," '{print $1}'`
S3_BACKUP="your-s3-backup-bucket-$INST_REGION/efs-backup"
S3_LOGS="your-s3-logs-bucket-$INST_REGION/efs-backup"
LOG_FILE="efs-backup-log_$DATE.txt"
AWS_CLI=`which aws`
MAC=`curl -s 169.254.169.254/latest/meta-data/network/interfaces/macs/`
VPC_ID=`curl -s 169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/vpc-id`
AZ=`curl -s 169.254.169.254/latest/dynamic/instance-identity/document | grep availabilityZone | xargs -l bash -c 'echo $2'| awk -F"," '{print $1}'`
SUCCESS_FS_DESCRIBE=0
RETRIES=0


echo "START `date +%Y-%m-%d-%T`" >> $LOG_FILE
echo "Instance VPC_ID: $VPC_ID" >> $LOG_FILE

# find out which EFS mount points belongs to the same VPC as instance is

sleep `expr $RETRIES + 1`

while [ $SUCCESS_FS_DESCRIBE == "0" ]
do
FILE_SYSTEMS=`$AWS_CLI efs describe-file-systems --region $INST_REGION --query FileSystems[].FileSystemId --output text`
FILE_SYSTEMS_STATUS=$?
if [ $FILE_SYSTEMS_STATUS == "0" ]
echo "FILE SYSTEMS: $FILE_SYSTEMS" >> $LOG_FILE
then
SUCCESS_FS_DESCRIBE=1
fi
done


IFS=' ' read -ra IFS_FS <<< "$FILE_SYSTEMS"
if [ -z "$FILE_SYSTEMS" ]; then
	echo "NO FS found in region $INST_REGION!" >> $LOG_FILE
	else
		echo $FILE_SYSTEMS
		for VAR in $FILE_SYSTEMS
			do
                        sleep `expr $RETRIES + 1`
				SUCCESS_DESCRIBE_MOUNT_TARGETS="0"
				while [ $SUCCESS_DESCRIBE_MOUNT_TARGETS == "0" ]
				do
				echo "Checking for EFS $VAR" >> $LOG_FILE
				sleep `expr $RETRIES + 1`
				MOUNT_TARGETS=`$AWS_CLI efs describe-mount-targets --region $INST_REGION --file-system-id $VAR --query MountTargets[].SubnetId --output text`
				MOUNT_TARGETS_STATUS=$?
					if [ $MOUNT_TARGETS_STATUS == "0" ]
		                        then
					SUCCESS_DESCRIBE_MOUNT_TARGETS=1
					echo "MOUNT_TARGETS: $MOUNT_TARGETS" >> $LOG_FILE
		                        fi
				done

					
					for VAR2 in $MOUNT_TARGETS
						do
						echo "VAR2: $VAR2" >> $LOG_FILE
						sleep `expr $RETRIES + 1`
						SUCCESS_DESCRIBE_SUBNETS="0"
		                                while [ $SUCCESS_DESCRIBE_SUBNETS == "0" ]
							do
							echo "Checking for SUBNET $VAR2" >> $LOG_FILE
							sleep `expr $RETRIES + 1`
							FS_VPC_ID=`$AWS_CLI ec2 describe-subnets --subnet-id $VAR2 --region $INST_REGION --query Subnets[].VpcId --output text`
							FS_VPC_ID_STATUS=$?
                        				        if [ $FS_VPC_ID_STATUS == "0" ]
								then
								SUCCESS_DESCRIBE_SUBNETS=1
								echo "FS_VPC_ID: $FS_VPC_ID" >> $LOG_FILE
								fi
						done


							if [ "$VPC_ID" == "$FS_VPC_ID" ] 
								then
								echo "FOUND the same VPC ! Backup instance VPC: $VPC_ID, mount point subnet $VAR2, EFS mount point VPC: $FS_VPC_ID" >> $LOG_FILE
								SUCCESS_DESCRIBE_MOUNT_TARGETS2="0"
									while [ $SUCCESS_DESCRIBE_MOUNT_TARGETS2 == "0" ]
									do
									echo "Checking for IPs $VAR" >> $LOG_FILE
									sleep `expr $RETRIES + 1`
									EFS_IPS=`$AWS_CLI efs describe-mount-targets --region $INST_REGION --file-system-id $VAR --query MountTargets[].IpAddress --output text`
									EFS_IPS_STATUS=$?
										if [ $EFS_IPS_STATUS == "0" ]
										then
										echo "EFS_IPS: $EFS_IPS" >> $LOG_FILE
										SUCCESS_DESCRIBE_MOUNT_TARGETS2="1"
										fi
								done


#								echo "EFS_IPS: $EFS_IPS" >> $LOG_FILE
								for each in $EFS_IPS 
									do
									EFS_IP=$each
								done
								echo "EFS IP: $EFS_IP" >> $LOG_FILE
									if [ ! -d "$MOUNT_POINT" ]; then
										sudo mkdir -p $MOUNT_POINT
									fi
								echo "Mounting volume" >> $LOG_FILE
								sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 $EFS_IP:/ $MOUNT_POINT;
								mount_status=$?
                			                                if [ $mount_status -eq "0" ]; then
									echo "Doing S3 sync from $MOUNT_POINT to s3://$S3_BACKUP/$VAR/" >> $LOG_FILE
									$AWS_CLI s3 sync $MOUNT_POINT s3://$S3_BACKUP/$VAR/ --delete --no-follow-symlinks >> $LOG_FILE
									s3_sync_status=$?
									if [ $s3_sync_status -eq "0" ]; then
										echo "EFS S3 sync succeeded from $MOUNT_POINT to s3://$S3_BACKUP/$VAR/" >> $LOG_FILE
									else
										echo "EFS S3 sync failed from $MOUNT_POINT to s3://$S3_BACKUP/$VAR/" >> $LOG_FILE
		                                                	        $AWS_CLI sns publish --topic-arn "$SNS_TOPIC" --subject "S3 sync for EFS backup failed for $VAR" --message "S3 sync for EFS $VAR backup failed in $INST_REGION" --region us-east-1
									fi
						echo "Umounting volume" >> $LOG_FILE
						sudo umount $MOUNT_POINT
						if [ "$?" -ne "0" ]; then
						echo "EFS Umount failed for $EFS_IP" >> $LOG_FILE
						$AWS_CLI sns publish --topic-arn "$SNS_TOPIC" --subject "EFS mount failed for EFS $VAR" --message "EFS Umount failed for $EFS_IP" --region us-east-1
						fi

						else
							echo "EFS Mount failed from $MOUNT_POINT to s3://$S3_BACKUP/$VAR/" >> $LOG_FILE
                                                        $AWS_CLI sns publish --topic-arn "$SNS_TOPIC" --subject "EFS mount failed for EFS $VAR" --message "EFS mount failed for EFS $VAR and it's IP $EFS_IP in $INST_REGION; $MOUNT_POINT to s3://$S3_BACKUP/$VAR/ failed" --region us-east-1
						break
						fi
						else 
							echo "NO FS found in the same VPC as this instance. Backup instance VPC: $VPC_ID, mount point subnet $VAR2, EFS VPC: $FS_VPC_ID" >> $LOG_FILE
					fi
				done
			done
		echo "" >> $LOG_FILE

fi
echo "END `date +%Y-%m-%d-%T`" >> $LOG_FILE

$AWS_CLI s3 cp $LOG_FILE s3://$S3_LOGS/$VPC_ID/$YEAR/$MONTH/$DAY/$TIME/$LOG_FILE
