# Andy Pham Resume Website - AWS Deployment Script
# Run from PowerShell: cd C:\Projects; .\deploy.ps1

$REGION = "us-east-1"
$BUCKET_SUFFIX = Get-Random -Minimum 10000 -Maximum 99999
$BUCKET_NAME = "andytangpham-resume-$BUCKET_SUFFIX"
$LAMBDA_NAME = "andypham-resume-chatbot"
$LAMBDA_ROLE = "andypham-resume-lambda-role"
$API_NAME = "andypham-resume-api"
$MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001"
$PROJECT_DIR = "C:\Projects"
$LAMBDA_DIR = "$PROJECT_DIR\lambda"
$TEMP_DIR = "$env:TEMP\andypham-deploy"
New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null

Write-Host "=== Andy Pham Resume Site Deployment ===" -ForegroundColor Cyan
Write-Host "Bucket: $BUCKET_NAME" -ForegroundColor Yellow

# STEP 1: Create S3 bucket + configure static website
Write-Host "`n[1/8] Creating S3 bucket..." -ForegroundColor Green
aws s3 mb "s3://$BUCKET_NAME" --region $REGION

aws s3api put-public-access-block `
  --bucket $BUCKET_NAME `
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

aws s3 website "s3://$BUCKET_NAME" --index-document index.html --error-document index.html

$BUCKET_POLICY_FILE = "$TEMP_DIR\bucket-policy.json"
@"
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
  }]
}
"@ | Set-Content -Path $BUCKET_POLICY_FILE -Encoding UTF8
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy "file://$BUCKET_POLICY_FILE"

# STEP 2: Upload site files
Write-Host "`n[2/8] Uploading site files..." -ForegroundColor Green
aws s3 cp "$PROJECT_DIR\index.html" "s3://$BUCKET_NAME/index.html" --content-type "text/html"
aws s3 cp "$LAMBDA_DIR\context.md" "s3://$BUCKET_NAME/context.md" --content-type "text/markdown"

# STEP 3: Create IAM role for Lambda
Write-Host "`n[3/8] Creating IAM role..." -ForegroundColor Green
$TRUST_POLICY_FILE = "$TEMP_DIR\trust-policy.json"
@'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
'@ | Set-Content -Path $TRUST_POLICY_FILE -Encoding UTF8

try {
  aws iam create-role --role-name $LAMBDA_ROLE --assume-role-policy-document "file://$TRUST_POLICY_FILE" --query 'Role.Arn' --output text | Out-Null
} catch {}
$ROLE_ARN = aws iam get-role --role-name $LAMBDA_ROLE --query 'Role.Arn' --output text
Write-Host "Role ARN: $ROLE_ARN"
aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
Write-Host "Waiting 15s for IAM propagation..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# STEP 4: Package Lambda
Write-Host "`n[4/8] Packaging Lambda..." -ForegroundColor Green
$ZIP_PATH = "$TEMP_DIR\andypham-lambda.zip"
if (Test-Path $ZIP_PATH) { Remove-Item $ZIP_PATH }
Compress-Archive -Path "$LAMBDA_DIR\handler.py" -DestinationPath $ZIP_PATH

# STEP 5: Create or update Lambda function
Write-Host "`n[5/8] Deploying Lambda function..." -ForegroundColor Green
$EXISTING = aws lambda get-function --function-name $LAMBDA_NAME --query 'Configuration.FunctionName' --output text 2>&1
if ($EXISTING -eq $LAMBDA_NAME) {
  Write-Host "Updating existing Lambda..."
  aws lambda update-function-code --function-name $LAMBDA_NAME --zip-file "fileb://$ZIP_PATH" | Out-Null
  aws lambda update-function-configuration --function-name $LAMBDA_NAME --environment "Variables={BUCKET_NAME=$BUCKET_NAME,CONTEXT_KEY=context.md,MODEL_ID=$MODEL_ID,ALLOWED_ORIGIN=*}" | Out-Null
} else {
  Write-Host "Creating new Lambda..."
  aws lambda create-function --function-name $LAMBDA_NAME --runtime python3.12 --role $ROLE_ARN --handler handler.lambda_handler --zip-file "fileb://$ZIP_PATH" --timeout 30 --memory-size 256 --environment "Variables={BUCKET_NAME=$BUCKET_NAME,CONTEXT_KEY=context.md,MODEL_ID=$MODEL_ID,ALLOWED_ORIGIN=*}" | Out-Null
}
aws lambda wait function-active --function-name $LAMBDA_NAME
$LAMBDA_ARN = aws lambda get-function --function-name $LAMBDA_NAME --query 'Configuration.FunctionArn' --output text
Write-Host "Lambda ARN: $LAMBDA_ARN"

# STEP 6: Create API Gateway
Write-Host "`n[6/8] Creating API Gateway..." -ForegroundColor Green
$EXISTING_API = aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text
if ($EXISTING_API) {
  $API_ID = $EXISTING_API
  Write-Host "Using existing API: $API_ID"
} else {
  $API_ID = aws apigateway create-rest-api --name $API_NAME --query 'id' --output text
  Write-Host "Created API: $API_ID"
}
$ROOT_ID = aws apigateway get-resources --rest-api-id $API_ID --query 'items[?path==`/`].id' --output text
$CHAT_ID = aws apigateway get-resources --rest-api-id $API_ID --query "items[?path=='/chat'].id" --output text
if (-not $CHAT_ID) {
  $CHAT_ID = aws apigateway create-resource --rest-api-id $API_ID --parent-id $ROOT_ID --path-part "chat" --query 'id' --output text
}
Write-Host "Chat resource: $CHAT_ID"
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text

# POST method with Lambda proxy
aws apigateway put-method --rest-api-id $API_ID --resource-id $CHAT_ID --http-method POST --authorization-type NONE 2>&1 | Out-Null
aws apigateway put-integration --rest-api-id $API_ID --resource-id $CHAT_ID --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" 2>&1 | Out-Null

# OPTIONS method for CORS preflight
$REQ_TEMPLATES_FILE = "$TEMP_DIR\req-templates.json"
@'
{"application/json":"{\"statusCode\":200}"}
'@ | Set-Content -Path $REQ_TEMPLATES_FILE -Encoding UTF8

aws apigateway put-method --rest-api-id $API_ID --resource-id $CHAT_ID --http-method OPTIONS --authorization-type NONE 2>&1 | Out-Null
aws apigateway put-integration --rest-api-id $API_ID --resource-id $CHAT_ID --http-method OPTIONS --type MOCK --request-templates "file://$REQ_TEMPLATES_FILE" 2>&1 | Out-Null

$METHOD_RESP_PARAMS_FILE = "$TEMP_DIR\method-resp-params.json"
@'
{"method.response.header.Access-Control-Allow-Headers":false,"method.response.header.Access-Control-Allow-Methods":false,"method.response.header.Access-Control-Allow-Origin":false}
'@ | Set-Content -Path $METHOD_RESP_PARAMS_FILE -Encoding UTF8
aws apigateway put-method-response --rest-api-id $API_ID --resource-id $CHAT_ID --http-method OPTIONS --status-code 200 --response-parameters "file://$METHOD_RESP_PARAMS_FILE" 2>&1 | Out-Null

$INT_RESP_PARAMS_FILE = "$TEMP_DIR\int-resp-params.json"
@'
{"method.response.header.Access-Control-Allow-Headers":"'Content-Type,Authorization'","method.response.header.Access-Control-Allow-Methods":"'POST,OPTIONS'","method.response.header.Access-Control-Allow-Origin":"'*'"}
'@ | Set-Content -Path $INT_RESP_PARAMS_FILE -Encoding UTF8
aws apigateway put-integration-response --rest-api-id $API_ID --resource-id $CHAT_ID --http-method OPTIONS --status-code 200 --response-parameters "file://$INT_RESP_PARAMS_FILE" 2>&1 | Out-Null

# Grant API Gateway permission to invoke Lambda
aws lambda add-permission --function-name $LAMBDA_NAME --statement-id "apigw-$(Get-Random)" --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/chat" 2>&1 | Out-Null

# STEP 7: Deploy API
Write-Host "`n[7/8] Deploying API to prod stage..." -ForegroundColor Green
aws apigateway create-deployment --rest-api-id $API_ID --stage-name prod | Out-Null
$API_ENDPOINT = "https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/chat"
Write-Host "API Endpoint: $API_ENDPOINT"

# STEP 8: Patch index.html and re-upload
Write-Host "`n[8/8] Patching index.html with live API endpoint..." -ForegroundColor Green
$HTML_PATH = "$PROJECT_DIR\index.html"
$HTML_CONTENT = Get-Content $HTML_PATH -Raw
$HTML_PATCHED = $HTML_CONTENT -replace "https://YOUR_API_GATEWAY_ID\.execute-api\.us-east-1\.amazonaws\.com/chat", $API_ENDPOINT
Set-Content -Path $HTML_PATH -Value $HTML_PATCHED -Encoding UTF8
aws s3 cp $HTML_PATH "s3://$BUCKET_NAME/index.html" --content-type "text/html"
Write-Host "index.html patched and re-uploaded."

# Cleanup temp files
Remove-Item -Recurse -Force $TEMP_DIR

$SITE_URL = "http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DEPLOYMENT COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Website: $SITE_URL" -ForegroundColor Yellow
Write-Host "  API:     $API_ENDPOINT" -ForegroundColor Yellow
Write-Host "  Bucket:  $BUCKET_NAME" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Open your site: $SITE_URL" -ForegroundColor Green