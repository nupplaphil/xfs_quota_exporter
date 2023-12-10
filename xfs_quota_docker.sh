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
  all_metrics=""

  for volume in "${volumes[@]}"; do
    # Extract project ID using lsattr
    volume_path="/var/lib/docker/165536.165536/volumes/${volume}"
    projectid_lsattr=$(lsattr -p "$volume_path" | awk '/\/_data/ {gsub(/[^0-9]/, "", $1); print $1}')

    # Find the corresponding quota information
    quota_info="${quota_array[$projectid_lsattr]}"

    # Extract values from quota_info
    used=$(( $(echo "$quota_info" | awk '{print $1}') * 1024 ))
    soft_limit=$(( $(echo "$quota_info" | awk '{print $2}')*1024 ))
    hard_limit=$(( $(echo "$quota_info" | awk '{print $3}')*1024 ))
  
    # Print metrics in Prometheus format
    all_metrics+="xfs_quota_used_bytes{volume=\"$volume\"} ${used}\n"
    all_metrics+="xfs_quota_soft_bytes{volume=\"$volume\"} ${soft_limit}\n"
    all_metrics+="xfs_quota_hard_bytes{volume=\"$volume\"} ${hard_limit}\n"
  done

  # Print metrics in Prometheus format
  echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n${all_metrics}" | nc -l -p 9101 -q 1
done
