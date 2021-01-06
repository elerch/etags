#!/usr/bin/env python3

import boto3
from requests_futures.sessions import FuturesSession

from concurrent.futures import as_completed
import json
import os
import sys
import traceback

session = FuturesSession()
ddb_url = os.getenv('DDB_ENDPOINT', None)
ddb = boto3.client('dynamodb', endpoint_url=ddb_url)
events = boto3.client('events')
table = os.getenv('ETAGS_TABLE', 'etags')
event_bus_name = os.getenv('ETAGS_BUS_NAME', 'url-content-changes')
force_change = os.getenv('ETAGS_FORCE_CHANGE', 'False') != 'False'


def printerr(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def ddb_url(url):
    return {
            'PK': {'S': url}
            }


def all_etags(urls):
    try:
        response = ddb.batch_get_item(RequestItems={table: {
            'Keys': [ddb_url(url) for url in urls],
            }})
        rc = {}
        for item in response['Responses'][table]:
            if 'etag' in item:
                rc[item['PK']['S']] = item['etag']['S']
        return rc
    except Exception as ex:
        printerr("Exception getting items: %s. Creating table", ex)
        response = ddb.create_table(
            TableName = table,
            AttributeDefinitions = [
                { 'AttributeName': 'PK', 'AttributeType': 'S' }
            ],
            KeySchema = [ { 'AttributeName': 'PK', 'KeyType': 'HASH' } ],
        )
        return all_etags(urls)


def create_put_request(item):
    return {
            'PutRequest': {
                'Item': {
                    'PK': {'S': item['url']},
                    'etag': {'S': item['etag']},
                },
            },
            }


def create_event(item):
    return {
            'Source': 'etags',
            'Resources': [item['url']],
            'Detail': json.dumps({'text': item['text']}),
            'DetailType': 'text-content',
            'EventBusName': event_bus_name,
            }


def process_changes(changed):
    # TODO: Deal with 25 max requests per call
    response = ddb.batch_write_item(RequestItems={
        table: [create_put_request(item) for item in changed]
        })
    unprocessed = {}
    if table in response['UnprocessedItems']:
        for item in response['UnprocessedItems'][table]:
            printerr('DDB did not process item with url %s' %
                     item['PutRequest']['Item']['PK']['S'])
            unprocessed[item['PutRequest']['Item']['PK']['S']] = True
    if event_bus_name != '':
        response = events.put_events(
            Entries=[create_event(item) for item in
                     filter(lambda k: k['url'] not in unprocessed, changed)]
        )
        if response['FailedEntryCount'] > 0:
            for entry in response['Entries']:
                printerr(json.dumps(entry))


def make_requests(urls, existing_etags):
    rs = []
    rsdict = {}
    for u in urls:
        if u in existing_etags and not force_change:
            etag = existing_etags[u]
            future = session.get(u, headers={'If-None-Match': etag})
        else:
            future = session.get(u)
        rsdict[future] = {'url': u}
        rs.append(future)
    return rs, rsdict


def lambda_handler(event, context):
    existing_etags = all_etags(event['urls'])
    (rs, rsdict) = make_requests(event['urls'], existing_etags)
    changed = []

    for future in as_completed(rs):
        try:
            result = future.result()
            if 'etag' not in result.headers:
                printerr('WARNING: Will not process, no etag found for %s' %
                         rsdict[future]['url'])
                break
            current_etag = result.headers['etag']
            prior_etag = None
            if rsdict[future]['url'] in existing_etags:
                prior_etag = existing_etags[rsdict[future]['url']]
            if force_change or current_etag != prior_etag:
                changed.append({
                    'url': rsdict[future]['url'],
                    'etag': current_etag,
                    'text': result.text,
                    })
        except Exception as ex:
            printerr('Error loading %s: %s' % (rsdict[future]['url'], ex))
            traceback.print_exc()

    if len(changed) > 0:
        print('changes detected')
        process_changes(changed)

    return {
        'statusCode': 200,
        'body': json.dumps(event)
    }


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: etags.py <url>')
        sys.exit(1)
    print(json.dumps(lambda_handler({'urls': sys.argv[1:]}, None)))
