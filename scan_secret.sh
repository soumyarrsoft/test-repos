#!/usr/bin/env bash

set -e

#-------------------------------------------------------------------------
# Description: This script scans all repositories of an Azure DevOps project and generates a CSV report.
#--------------------------------------------------------------------------
usage() {
  echo "usage: $0 -o <organization> -p <project_name>" 1>&2
  echo "where:" 1>&2
  echo "<organization_uri>: Azure DevOps Organization URI" 1>&2
  echo "<project_name>: Azure DevOps Project name" 1>&2
}

while getopts 'o:p:' OPTS; do
  case "$OPTS" in
  o)
    echo "Using the Azure DevOps Organization URI [$OPTARG] provided as input of this script"
    organization_uri=$OPTARG
    ;;
  p)
    echo "Using the Azure DevOps project name [$OPTARG] provided as input of this script"
    project_name=$OPTARG
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

# Variables
iteration=0

# Enable scripts to run Git commands
if [ ! -z "$GIT_USER_NAME" ] || [ ! -z "$GIT_USER_NAME" ]; then
  echo "Enable scripts to run Git commands for user.email $GIT_USER_EMAIL and user.name $GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  git config --global user.name "$GIT_USER_NAME"
else
  echo "Git user.email and user.name will use the current setting"
fi

# Create CSV header
echo "Repository, File, StartLine, RuleID, Description" > gitleaks_report.csv

# Action
## List Azure DevOps repos
repos=$(az repos list --organization "$organization_uri" --project "$project_name" --query "[?isDisabled == \`false\`]" | jq -r '.[] | @base64')

for repo in $repos; do
  _jqrepo() {
    echo ${repo} | base64 -d | jq -r ${1}
  }
  iteration=$((iteration + 1))
  repo_id=$(_jqrepo '.id')
  repo_name=$(_jqrepo '.name')
  repo_default_branch=$(_jqrepo '.defaultBranch')
  repo_url=$(_jqrepo '.webUrl')

  echo "[$iteration] Repo [$repo_name] with id [$repo_id] has the default branch [$repo_default_branch]"

  latest_ref_id=$(az repos ref list --organization "$organization_uri" \
    --project "$project_name" \
    --repository "$repo_id" \
    --filter heads --query "[?name=='${repo_default_branch}'].objectId" --output tsv)

  echo "[$iteration] Fetching the commit id [$latest_ref_id] of the Repo [$repo_name] on branch [$repo_default_branch]"

  echo "[$iteration] Clone the repo [$repo_url]"

  SOURCE_REPOSITORY_URI_SUFFIX=$(echo ${repo_url//https:\/\//})
  SOURCE_REPOSITORY_URI="https://$AZURE_DEVOPS_EXT_PAT@$SOURCE_REPOSITORY_URI_SUFFIX"

  git clone $SOURCE_REPOSITORY_URI $repo_id

  echo "[$iteration] Scanning the repo [$repo_url] with Gitleaks"

  cd $repo_id

  ../gitleaks/gitleaks detect -v --no-git --exit-code 0 --redact --report-format json --report-path ./gitleaks.json

  for secret in $(cat ./gitleaks.json | jq -r '.[] | @base64'); do
    _jqsecret() {
      echo ${secret} | base64 --decode | jq -r ${1}
    }
    description=$(_jqsecret '.Description')
    start_line=$(_jqsecret '.StartLine')
    file_path=$(_jqsecret '.File')
    rule_id=$(_jqsecret '.RuleID')

    # Append each secret to the CSV file
    echo "$repo_name, $file_path, $start_line, $rule_id, $description" >> ../gitleaks_report.csv

  done

  cd ../
  rm -rf $repo_id

done
