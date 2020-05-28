# frozen_string_literal: true

require 'yaml'
require 'time'
require 'restforce'
require 'rest-client'

def send_simple_message(subject, body)
  mg_config_file = YAML.load_file('/home/scott/Documents/Source/Utilities/apex-test-runner/mailgun.yml')
  url = 'https://api:' + mg_config_file[:api_key] + '@api.mailgun.net/v3/' + mg_config_file[:domain] + '/messages'
  RestClient.post url,
                  from: 'Decimal Mail Server <mailgun@mg.teamdecimal.com>',
                  to: 'scott@teamdecimal.com',
                  subject: subject,
                  html: body
end

config_file = YAML.load_file(ARGV[0])

sf_client = Restforce.new(
  username: config_file[:username],
  password: config_file[:password],
  security_token: config_file[:security_token],
  client_id: config_file[:client_id],
  client_secret: config_file[:client_secret],
  host: config_file[:host],
  api_version: config_file[:api_version]
)

sf_client.authenticate!
session_id = sf_client.options[:oauth_token]
url = sf_client.options[:instance_url]

body =
  "{ \"maxFailedTests\":
      \"-1\",
      \"testLevel\":
      \"RunLocalTests\",
      \"skipCodeCoverage\":
      \"false\"}"

exec_url = url + '/services/data/v47.0/tooling/runTestsAsynchronous/'
exec_response = ''
begin
  exec_response = RestClient.post(exec_url, body, content_type: :json, accept: :json, Authorization: 'Bearer ' + session_id)
rescue StandardError => e
  send_simple_message('Error from Apex Test Runner - Execution Call', e.message)
  return
end

id_url = url + '/services/data/v47.0/tooling/query/?q=select+Id+from+ApexTestRunResult+Where+AsyncApexJobId=\'' + exec_response.gsub(/"/, '') + '\''
id_response = ''
begin
  id_response = RestClient.get(id_url, content_type: :json, accept: :json, Authorization: 'Bearer ' + session_id)
rescue StandardError => e
  send_simple_message('Error from Apex Test Runner - Id Call', e.message)
  return
end

id_response_obj = JSON.parse(id_response.body)
id = id_response_obj['records'][0]['Id']

run_url = url + '/services/data/v47.0/tooling/sobjects/ApexTestRunResult/' + id + '/'
run_response_obj = {}
loop do
  run_response = ''
  begin
    run_response = RestClient.get(run_url, content_type: :json, accept: :json, Authorization: 'Bearer ' + session_id)
  rescue StandardError => e
    send_simple_message('Error from Apex Test Runner - Run Status Call', e.message)
    return
  end
  run_response_obj = JSON.parse(run_response.body)
  break if %w[Aborted Completed Failed].include?(run_response_obj['Status'])

  sleep(300)
end

results_url = url + '/services/data/v47.0/tooling/query/?q=select+Id,Outcome,ApexClass.Name,MethodName,Message,StackTrace+from+ApexTestResult+Where+ApexTestRunResultId=\'' + id + '\''
results_response = ''
begin
  results_response = RestClient.get(results_url, content_type: :json, accept: :json, Authorization: 'Bearer ' + session_id)
rescue StandardError => e
  send_simple_message('Error from Apex Test Runner - Results Call', e.message)
  return
end
results_response_obj = JSON.parse(results_response)
pass_count = results_response_obj['records'].select { |rec| rec['Outcome'] == 'Pass' }.length

mail_body = '<html><body>'
mail_body = mail_body + '<b>Test Class Execution Status as of ' + DateTime.now.to_s + ': ' + config_file[:environment] + '</b><br/><br/>'
mail_body = mail_body + '<b>Run Status: ' + run_response_obj['Status'] + '</b><br/>'
mail_body = mail_body + '<b>Tests Enqueued: ' + run_response_obj['MethodsEnqueued'].to_s + '</b><br/>'
mail_body = mail_body + '<b>Tests Passed: ' + pass_count.to_s + '</b><br/>'
mail_body = mail_body + '<b>Tests Failed: ' + run_response_obj['MethodsFailed'].to_s + '</b><br/><br/>'

if run_response_obj['MethodsFailed'] != 0
  mail_body += '<table style="width:100%" border="1">'
  mail_body += '<tr>' \
             '<td bgcolor="Blue"><b><font color="white">Status</font></b></td>' \
             '<td bgcolor="Blue"><b><font color="white">Class Name</font></b></td>' \
             '<td bgcolor="Blue"><b><font color="white">Method Name</font></b></td>' \
             '<td bgcolor="Blue"><b><font color="white">Message</font></b></td>' \
             '<td bgcolor="Blue"><b><font color="white">Stack Trace</font></b></td>' \
             '</tr>'
  results_response_obj['records'].each do |record|
    next if record['Outcome'] == 'Pass'

    mail_body += '<tr>'
    mail_body = mail_body + '<td>' + record['Outcome'] + '</td>'
    mail_body = mail_body + '<td>' + record['ApexClass']['Name'] + '</td>'
    mail_body = mail_body + '<td>' + record['MethodName'] + '</td>'
    mail_body = mail_body + '<td>' + record['Message'].to_s + '</td>'
    mail_body = mail_body + '<td>' + record['StackTrace'].to_s + '</td>'
    mail_body += '</tr>'
  end
  mail_body += '</table>'
end
mail_body += '</body></html>'

send_simple_message('Apex Test Run Results', mail_body)
