#!/usr/bin/env bash
# Tras reiniciar el task de ECS (nueva IP): apunta el origen ecs-nginx de CloudFront al nuevo DNS e invalida cache.
export AWS_DEFAULT_REGION=us-east-1
DIST=E3AABA7FCJGEFR
DNS=$1
aws cloudfront get-distribution-config --id $DIST > /tmp/cfcfg.json
ETAG=$(python3 -c "import json;print(json.load(open('/tmp/cfcfg.json'))['ETag'])")
python3 - "$DNS" <<'PY'
import json, sys
d = json.load(open('/tmp/cfcfg.json'))['DistributionConfig']
for o in d['Origins']['Items']:
    if o['Id'] == 'ecs-nginx':
        o['DomainName'] = sys.argv[1]
json.dump(d, open('/tmp/cfnew.json', 'w'))
PY
aws cloudfront update-distribution --id $DIST --if-match $ETAG --distribution-config file:///tmp/cfnew.json --query 'Distribution.Status' --output text
aws cloudfront create-invalidation --distribution-id $DIST --paths "/*" --query 'Invalidation.Status' --output text
