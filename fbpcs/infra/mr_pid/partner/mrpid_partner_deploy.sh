#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -e
# shellcheck disable=SC1091
source ./util.sh

usage() {
    echo "Usage: mrpid_partner_deploy.sh <deploy|undeploy>
        [ -t, --tag | A unique identifier to identify resources in this MR-PID deployment]
        [ -r, --region | MR-PID Partner AWS region, e.g. us-west-2 ]
        [ -a, --account_id | MR-PID Partner AWS account ID]
        [ -p, --publisher_account_id | MR-PID Publisher AWS account ID]
        [ -i, --pce_instance_id | Publisher PCE instance ID]
        [ -u, --partner_unique_tag | Partner Deployment unique Tag]
        [ -b, --bucket | optional. S3 bucket name for storing configs: tfstate]"
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

undeploy=false
case "$1" in
    deploy) ;;
    undeploy) undeploy=true ;;
    *) usage ;;
esac
shift

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--tag) pid_id="$2" ;;
        -r|--region) region="$2" ;;
        -a|--account_id) aws_account_id="$2" ;;
        -p|--publisher_account_id) publisher_account_id="$2" ;;
        -i|--pce_instance_id) pce_instance_id="$2" ;;
        -u|--partner_unique_tag) partner_unique_tag="$2" ;;
        -b|--bucket) s3_bucket_for_storage="$2" ;;
        *) usage ;;
    esac
    shift
    shift
done

#### Terraform Logs
if [ -z ${TF_LOG+x} ]; then
    echo "Terraform Detailed Error Logging Disabled"
else
    echo "Terraform Log Level: $TF_LOG"
    echo "Terraform Log File: $TF_LOG_PATH"
    echo "Terraform Log File: $TF_LOG_STREAMING"
    echo
fi

undeploy_aws_resources () {
    input_validation "$region" "$pid_id" "$aws_account_id" "$publisher_account_id" "$s3_bucket_for_storage"
    echo "Start undeploying MR-PID Partner resources..."
    echo "########################Check tfstate files########################"
    check_s3_object_exist "$s3_bucket_for_storage" "tfstate/pid$tag_postfix.tfstate" "$aws_account_id"
    echo "All tfstate files exist. Continue..."

    echo "########################Delete MR-PID resources########################"
    cd /terraform_deployment/terraform_scripts
    terraform init \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/pid$tag_postfix.tfstate"
    terraform destroy \
        -auto-approve \
        -var "aws_region=$region" \
        -var "pid_id=$pid_id" \
        -var "pce_instance_id=$pce_instance_id" \
        -var "publisher_account_id=$publisher_account_id" \
        -var "partner_unique_tag=$partner_unique_tag"
}

deploy_aws_resources () {
    input_validation "$region" "$pid_id" "$aws_account_id" "$publisher_account_id" "$s3_bucket_for_storage"
    # Clean up previously generated resources if any
    cleanup_generated_resources
    echo "########################Started MR-PID AWS Infrastructure Deployment########################"
    echo "creating s3 bucket, if it does not exist"
    validate_or_create_s3_bucket "$s3_bucket_for_storage" "$region" "$aws_account_id"

    # Deploy MR-PID Partner Terraform scripts
    cd /terraform_deployment/terraform_scripts
    terraform init \
        -backend-config "bucket=$s3_bucket_for_storage" \
        -backend-config "region=$region" \
        -backend-config "key=tfstate/pid$tag_postfix.tfstate"
    terraform apply \
        -auto-approve \
        -var "aws_region=$region" \
        -var "pid_id=$pid_id" \
        -var "pce_instance_id=$pce_instance_id" \
        -var "publisher_account_id=$publisher_account_id" \
        -var "partner_unique_tag=$partner_unique_tag"

    state_machine_arn=$(terraform output mrpid_partner_sfn_arn | tr -d '"' )

    echo "########################Finished MR-PID AWS Infrastructure Deployment########################"

    echo "########################Start populating config_mrpid.yml ########################"

    cd /terraform_deployment
    sed -i "s/region: .*/region: $region/g" config_mrpid.yml
    echo "Populated region with value $region"

    sed -i "s/stateMachineArn: .*/stateMachineArn: $state_machine_arn/g" config_mrpid.yml
    echo "Populated stateMachineArn with value $state_machine_arn"

    echo "########################Upload config_mrpid.ymls to S3########################"
    cd /terraform_deployment
    aws s3api put-object --bucket "$s3_bucket_for_storage" --key "config_mrpid.yml" --body ./config_mrpid.yml
    echo "########################Finished upload config_mrpid.ymls to S3########################"
}

##########################################
# Main
##########################################

tag_postfix="-${pid_id}"

# if no input for bucket names, then go by default

if [ -z ${s3_bucket_for_storage+x} ]
then
    # s3_bucket_for_storage is unset
    s3_bucket_for_storage="fb-pc-mrpid-partner-config$tag_postfix"
else
    # s3_bucket_for_storage is set, but add tags to it
    s3_bucket_for_storage="$s3_bucket_for_storage$tag_postfix"
fi

echo "MR-PID Partner AWS region is $region."
echo "MR-PID Partner AWS acount ID is $aws_account_id"
echo "MR-PID Publisher AWS acount ID is $publisher_account_id"
echo "Publisher PCE instance ID is $pce_instance_id"
echo "Partner Deployment unique Tag is $partner_unique_tag"
echo "The S3 bucket for storing the Terraform state file is $s3_bucket_for_storage and it is in region $region"

if "$undeploy"
then
    echo "Undeploying the MR-PID Partner AWS resources..."
    undeploy_aws_resources
else
    deploy_aws_resources
fi
exit 0
