# etags

Checks urls for etags and reports back any changed urls. Requires [DynamoDb](https://aws.amazon.com/dynamodb/),
or something like it. For a lightweight, self-hosted version, you can try
[DynamoDb Bolt](https://github.com/elerch/ddbbolt).

Usage: `etags.py <url> ...`

## Environment variables

  * ETAGS_BUS_NAME: If set, this will notify on an [EventBridge bus](https://aws.amazon.com/eventbridge/)
  * ETAGS_TABLE: Table name for DynamoDB
  * DDB_ENDPOINT: By default, the application will use DynamoDb's standard endpoint
                  Set this variable if using a non-standard endpoint or DynamoDb Bolt

This uses boto3, so all [AWS Environment Variables](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html)
will control authentication. If using DynamoDb Bolt, the following must be set,
but can be dummy values:

  * AWS_DEFAULT_REGION
  * AWS_ACCESS_KEY_ID
  * AWS_SECRET_ACCESS_KEY

# Running as Docker

Latest version can be found at [https://r.lerch.org/repo/etags/tags/](https://r.lerch.org/repo/etags/tags/).
Versions are tagged with the short hash of the git commit, and are
built as a multi-architecture image based on a scratch image.

You can run the docker image with a command like:

```sh
docker run \
  --rm                              \
  --tmpfs /tmp                      \
  --name=ddbbolt                    \
  -e AWS_DEFAULT_REGION=us-west-2   \
  -e AWS_ACCESS_KEY_ID=AKIAEXAMPLE  \
  -e AWS_SECRET_ACCESS_KEY=dummy    \
  -e DDB_ENDPOINT=set_if_applicable \
  -e ETAGS_TABLE=etags              \
  r.lerch.org/etags:0af6716
```
