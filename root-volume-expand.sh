#!/bin/bash
set -o errexit

if [ ! $1 ] ; then
  echo "Usage: $0 -i/-instance <instance id> -s/-size <size of new volume> -r/-region <amazon region>"
  exit 1
fi

while getopts :i:s:r: opt; do
  case $opt in
  i)
      instanceid=$OPTARG
      ;;
  s)
      size=$OPTARG
      ;;
  r)
      region=$OPTARG
      ;;
  esac
done

if [ ! $instanceid ]; then
  echo "instance id required!"
  exit 1
fi

if [ -z $size ]; then
  echo "no size entered, defaulting to 40 Gb."
  # Set a reasonable default size if unset
  size=40
fi

if [ ! $region ]; then
  echo "using default region us-east-1"
  region="us-east-1"
fi

rootdevice=$(aws ec2 describe-instances \
  --region "$region" \
  --instance-ids $instanceid \
  --output text \
  --query 'Reservations[*].Instances[*].RootDeviceName')

oldvolumeid=$(aws ec2 describe-instances \
  --region "$region" \
  --instance-ids $instanceid \
  --output text \
  --query 'Reservations[*].Instances[*].BlockDeviceMappings[?DeviceName==`'$rootdevice'`].[Ebs.VolumeId]')

zone=$(aws ec2 describe-instances \
  --region "$region" \
  --instance-ids $instanceid \
  --output text \
  --query 'Reservations[*].Instances[*].Placement.AvailabilityZone')

if [ ! $zone ]; then
  echo "can't find availability zone!"
  exit 1
fi

if [ ! $oldvolumeid ]; then
  echo "no volume detected!"
  #Allow users to enter a custom volume in case script failed after detaching
  printf "Do you want to manually enter a volume ID? [Y/n] :"
  read CUSTOMVOL
  if [[ $CUSTOMVOL == "y" ]] || [[ $CUSTOMVOL == "Y" ]]; then
    echo ""
    printf "enter volume ID :"
    read VOLUME
    oldvolumeid=$VOLUME
      if [ -z $oldvolumeid ]; then
        echo "volume null, aborting."
        exit 1
      fi
  else
    echo "OK, Aborting."
    exit 1
  fi
else
  checkvol=1
fi

set -o nounset

echo "This will stop instance $instanceid in region $region and zone $zone with original volume $oldvolumeid."
printf "Are you sure you want to proceed? [Y/n] :"
read CONFIRM
if [[ $CONFIRM == "y" ]] || [[ $CONFIRM == "Y" ]]; then
        echo "Starting resize operation now."
else
        echo "Acknowledged, Y was not chosen.  Exiting."
        exit 1
fi

zone=$(aws ec2 describe-instances $instanceid --region=$region|grep "^INSTANCE" | cut -f12)
aws ec2 stop-instances \
  --region "$region" \
  --instance-ids $instanceid
aws ec2 wait instance-stopped \
  --region "$region" \
  --instance-ids $instanceid

echo "OK. Stopping instance $instanceid in region $region and zone $zone with original volume $oldvolumeid now."
ec2-stop-instances $instanceid --region=$region

if [[ checkvol == 1 ]]; then
    echo "detaching volume..."
    while ! ec2-detach-volume $oldvolumeid --region=$region; do sleep 5; done
    aws ec2 detach-volume \
      --region "$region" \
      --volume-id $oldvolumeid
    aws ec2 wait volume-available \
      --region "$region" \
      --volume-ids $oldvolumeid
fi

snapshotid=$(aws ec2 create-snapshot \
  --region "$region" \
  --volume-id "$oldvolumeid" \
  --output text \
  --query 'SnapshotId')
aws ec2 wait snapshot-completed \
  --region "$region" \
  --snapshot-ids "$snapshotid"
echo "snapshot: $snapshotid"

echo "creating new volume..."
newvolumeid=$(aws ec2 create-volume \
  --region "$region" \
  --availability-zone "$zone" \
  --size "$size" \
  --snapshot "$snapshotid" \
  --output text \
  --query 'VolumeId')

echo "new volume: $newvolumeid. waiting for volume creation to finish..."

# Waiting for volume to create
sleep 15
echo "attaching new volume to $instanceid"
aws ec2 attach-volume \
  --region "$region" \
  --instance "$instanceid" \
  --device "$rootdevice" \
  --volume-id "$newvolumeid"
aws ec2 wait volume-in-use \
  --region "$region" \
  --volume-ids "$newvolumeid"

echo "starting instance..."
aws ec2 start-instances \
  --region "$region" \
  --instance-ids "$instanceid"
aws ec2 wait instance-running \
  --region "$region" \
  --instance-ids "$instanceid"
aws ec2 describe-instances \
  --region "$region" \
  --instance-ids "$instanceid"

echo "deleting snapshot of resized volume"
aws ec2 delete-snapshot \
  --region "$region" \
  --snapshot-id "$snapshotid"

echo "When satisfied, you can run 
`aws ec2 delete-volume \
  --region $region \
  --volume-id $oldvolumeid`
 to clean up the old volume."

printf "Would you like to clean up the old volume now? [Y/n] :"
read DELETE
if [[ $DELETE == "y" ]] || [[ $DELETE == "Y" ]]; then
        echo "Acknowledged, deleting old volume."
        aws ec2 delete-volume \
          --region "$region" \
          --volume-id "$oldvolumeid"
else
        echo "Acknowledged, Y was not chosen. Exiting."
        exit 1
fi
