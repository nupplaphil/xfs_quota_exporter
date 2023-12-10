#!/bin/bash
set -eo pipefail

IFS=$'\n'

# Get the list of volumes
volumes=( $( docker volume ls | tr -s " " | tail -n +2 | grep -w 'local' | awk '{print $2}') )

# Initialize an associative array to store quota information
declare -A quota_array

# Populate quota_array with project ID and quota information
while read -r line; do
    project_id=$(echo "$line" | awk '{print substr($1,2)}')
    quota_info=$(echo "$line" | cut -d ' ' -f 2-)
    quota_array["$project_id"]="$quota_info"
done < <(xfs_quota -x -c 'report -N' /var/lib/docker | sed -n '/^$/{:a;n;p;ba}' | sed '/^$/d' | tr -s " ")

result=()

# Start netcat to serve metrics on port 9101
while true; do
  # Initialize variable to store all metrics
  all_metrics_used="# HELP xfs_quota_used_bytes Number of used bytes of the docker volumes\n# TYPE xfs_quota_used_bytes gauge\n"
  all_metrics_soft_limit="# HELP xfs_quota_soft_limit_bytes The soft limit of the docker volumes\n# TYPE xfs_quota_soft_limit_bytes gauge\n"
  all_metrics_hard_limit="# HELP xfs_quota_hard_limit_bytes The hard limit of the docker volumes\n# TYPE xfs_quota_hard_limit_bytes gauge\n"
  xfs_quota_used_sum=0
  xfs_quota_soft_limit_sum=0
  xfs_quota_hard_limit_sum=0
  xfs_quota_used_count=0
  xfs_quota_soft_limit_count=0
  xfs_quota_hard_limit_count=0

  for volume in "${volumes[@]}"; do
    # Extract project ID using lsattr
    volume_path="/var/lib/docker/165536.165536/volumes/${volume}"
    projectid_lsattr=$(lsattr -p "$volume_path" | awk '/\/_data/ {gsub(/[^0-9]/, "", $1); print $1}')

    if [[ $projectid_lsattr -eq 0 ]]; then
      continue
    fi

    # Find the corresponding quota information
    quota_info="${quota_array[$projectid_lsattr]}"

    # Extract values from quota_info
    used=$(( $(echo "$quota_info" | awk '{print $1}') * 1024 ))
    soft_limit=$(( $(echo "$quota_info" | awk '{print $2}')*1024 ))
    hard_limit=$(( $(echo "$quota_info" | awk '{print $3}')*1024 ))
  
    # Print metrics in Prometheus format
    all_metrics_used+="xfs_quota_used_bytes{volume=\"$volume\",pid=\"$projectid_lsattr\"} ${used}\n"
    all_metrics_soft_limit+="xfs_quota_soft_limit_bytes{volume=\"$volume\",pid=\"$projectid_lsattr\"} ${soft_limit}\n"
    all_metrics_hard_limit+="xfs_quota_hard_limit_bytes{volume=\"$volume\",pid=\"$projectid_lsattr\"} ${hard_limit}\n"

    xfs_quota_used_count=$(( xfs_quota_used_count + 1 ))
    xfs_quota_soft_limit_count=$(( xfs_quota_soft_limit_count + 1 ))
    xfs_quota_hard_limit_count=$(( xfs_quota_hard_limit_count + 1 ))
  done

  all_metrics_used+="xfs_quota_used_count ${xfs_quota_used_count}"
  all_metrics_soft_limit+="xfs_quota_soft_limit_count ${xfs_quota_soft_limit_count}"
  all_metrics_hard_limit+="xfs_quota_hard_limit_count ${xfs_quota_hard_limit_count}"

  # Print metrics in Prometheus format
  echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n${all_metrics_used}\n${all_metrics_soft_limit}\n${all_metrics_hard_limit}" | nc -l -p 9101 -q 1
done
