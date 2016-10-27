# expand-ebs-root-volume
Expands an EC2 instance's root volume. Requires instance downtime.

This script started life as Eric Hammond's excellent [blog post](https://alestic.com/2010/02/ec2-resize-running-ebs-root/) on the topic. It's been turned into a script suitable for a variety of different use cases, including iterative resizing for a fleet.

## Usage

```
root-volume-expand.sh $instance-id
```

