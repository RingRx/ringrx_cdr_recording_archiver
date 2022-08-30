#!/usr/bin/ruby
# frozen_string_literal: true

require 'httparty'
require 'httmultiparty'
require 'json'
require 'yaml'
require 'logger'
require 'pp'
require 'fileutils'

####################################################################
### Defining functions
####################################################################

  def init
    @conffile = YAML.load_file('./archiver.conf')

    dest_dir = @conffile['destination_dir']
    Dir.mkdir(dest_dir) unless Dir.exist?(dest_dir)

    db_dir = "db/"
    Dir.mkdir(db_dir) unless Dir.exist?(db_dir)

    log_dir = "logs/"
    Dir.mkdir(log_dir) unless Dir.exist?(log_dir)

    cdr_dir = @conffile['cdrdir']
    Dir.mkdir(cdr_dir) unless Dir.exist?(cdr_dir)

    tmp_dir = @conffile['tempdir']
    Dir.mkdir(tmp_dir) unless Dir.exist?(tmp_dir)

    logfile = "logs/#{@conffile['logfile']}"
    logfilerotation = (@conffile['logfilerotation']).to_s

    $LOG = Logger.new(logfile, logfilerotation)
    $LOG.level =  Logger::DEBUG
  end

  def auth
    body = {}
    body[:username] = @conffile['acct_username']
    body[:password] = @conffile['acct_password']

    response = HTTParty.post("#{@conffile['portal_url']}/auth/token",
      body: body.to_json,
      timeout: 10,
      headers: { 'Content-Type' => 'application/json' },
      verify: false )
    return response
  end

  def request_headers(token)
    headers = {}
    headers['Content-Type'] = "application/json"
    headers['Authorization'] = token
    return headers
  end

  def fetch_cdrs(token)
    url = "#{@conffile['portal_url']}/cdrs?getAll=true"
    unless File.exists?(File.join('db','cdrids'))
      start_date = (Time.now - 31557600).strftime("%d-%m-%Y")
      end_date = Time.now.strftime("%d-%m-%Y")
      url = "#{@conffile['portal_url']}/cdrs?getAll=true&startDate=#{start_date}&endDate=#{end_date}"
    end  
    response = HTTParty.get(url,
      timeout: 10,
      headers: request_headers(token),
      verify: false )
    return response
  end

  def fetch_recording(cdrid)
    url = "#{@conffile['portal_url']}/cdrs/#{cdrid}/recording"
    response = HTTParty.get(url,
      :timeout => 10,
      :headers => request_headers(token),
      :verify => false )
    return response
  end

  def file_name(msg)
    if msg["message_type"] == "message"
      file_ext = "txt"
    elsif msg["message_type"] == "fax"
      file_ext = msg["fax"].split(".").last
    elsif msg["message_type"] == "voicemail"
      file_ext = msg["voicemail"].split(".").last
    end
    file_str = "#{@conffile['destination_filename']}.#{file_ext}"
    output = file_str.gsub("{id}", msg["id"]).gsub("{caller}", msg["caller"]).gsub("{called}", msg["called"]).gsub("{created}", msg["created_at"]).gsub(" ", "_").gsub("{mailbox}", msg["mailbox"]).gsub("{type}", msg["message_type"]).gsub(':', '.')
    return output
  end

  def check_cdr_id(call)
    dbfile = File.join('db','cdrids')
    result = true
    if File.exists?(dbfile)
      last_id = IO.readlines(dbfile)[-1]
      $LOG.debug "checking last ID of #{last_id} against call id #{call['id']} #{last_id.to_i >= call['id'].to_i}"
      if last_id.to_i >= call['id'].to_i
        result = false
      else
        File.open(dbfile, 'w') { |f| f.write(call['id']) }
      end
    else
      File.open(dbfile, 'w') { |f| f.write(call['id']) }
    end
    return result
  end

  def cdr_recorded?(call)
    recorded = false
    if !call['recording_key'].nil? && call['recording_key'].length > 0
      recorded = true
    end
    return recorded
  end

  def cdr_filename(call)
    File.join(@conffile['cdrdir'], "#{call['start_time'].split(' ').first}.csv")
  end

  def cdr_file(call)
    file_headers = "id,responsible_party,start_time,hangup_cause,calling_party,called_party,caller_id_number,caller_id_name,duration,bill_duration,direction,mailbox,aleg_holdtime,bleg_holdtime,recorded,tags\n"
    unless File.exists?(cdr_filename(call))
      File.open(cdr_filename(call), 'a') {|f| f.write(file_headers) }
    end
  end
  
  def write_cdr(call)
    cdr_file(call)
    call_line = "\"#{call['id']}\",\"#{call['responsible_party']}\",\"#{call['start_time']}\",\"#{call['hangup_cause']}\",\"#{call['calling_party']}\",\"#{call['called_party']}\",\"#{call['caller_id_number']}\",\"#{call['caller_id_name']}\",\"#{call['duration']}\",\"#{call['bill_duration']}\",\"#{call['direction']}\",\"#{call['mailbox']}\",\"#{call['aleg_holdtime']}\",\"#{call['bleg_holdtime']}\",\"#{cdr_recorded?(call).to_s}\",\"#{call['tags']}\"\n"
    File.open(cdr_filename(call), 'a') {|f| f.write(call_line) }
  end

  def file_name(call)
    file_ext = call["recording_key"].gsub('.enc','').split(".").last rescue ''
    file_str = "#{@conffile['destination_filename']}.#{file_ext}"
    output = file_str.gsub("{id}", call['id'])
    output = output.gsub("{responsible_party}", call['responsible_party']) if call['responsible_party']
    output = output.gsub("{start_time}", call['start_time'])
    output = output.gsub("{hangup_cause}", call['hangup_cause']) if call['hangup_cause']
    output = output.gsub("{calling_party}", call['calling_party']) if call['calling_party']
    output = output.gsub("{called_party}", call['called_party']) if call['called_party']
    output = output.gsub("{caller_id_number}", call['caller_id_number']) if call['caller_id_number']
    output = output.gsub("{caller_id_name}", call['caller_id_name']) if call['caller_id_name']
    output = output.gsub("{duration}", call['duration']) if call['duration']
    output = output.gsub("{bill_duration}", call['bill_duration']) if call['bill_duration']
    output = output.gsub("{direction}", call['direction']) if call['direction']
    output = output.gsub("{mailbox}", call['mailbox']) if call['mailbox']
    output = output.gsub("{aleg_holdtime}", call['aleg_holdtime']) if call['aleg_holdtime']
    output = output.gsub("{bleg_holdtime}", call['bleg_holdtime']) if call['bleg_holdtime']
    output = output.gsub("{tags}", call['tags'])
    output = output.gsub(' ', '_')
    $LOG.debug "Filename will be: #{output}"
    return output
  end

  def fetch_recording(call, token)
    url = "#{@conffile['portal_url']}/cdrs/#{call['id']}/recording"
    response = HTTParty.get(url,
      :timeout => 60,
      :headers => request_headers(token),
      :verify => false )
    return response
  end

  def save_recording(call, token)
    $LOG.warn "Processing recording for #{call['id']}"
    recording_file = fetch_recording(call, token)
    $LOG.warn "Retrieved #{recording_file.inspect}"
    if recording_file.code == 200
      File.open(File.join(@conffile['destination_dir'], file_name(call)), 'wb') { |f| f.write(recording_file.body) }
    end
  end

####################################################################
### Main app logic
####################################################################

init
auth_resp = auth

if auth_resp.code == 200
  $LOG.debug "auth succeeded..setting auth token to #{auth_resp['access_token']}"
  @auth_token = auth_resp['access_token']
end

if @auth_token
  $LOG.warn "Performing cdr fetch operation"
  $LOG.debug "received auth token. Good to proceed"
  $LOG.debug "Fetching cdrs"

  cdrs = fetch_cdrs(@auth_token).parsed_response
  cdrs.sort_by { |c| c['id'] }.each do |cdr|
    if check_cdr_id(cdr)
      write_cdr(cdr)
      $LOG.debug cdr
      if cdr_recorded?(cdr)
        $LOG.debug "Fetching recording for #{cdr['id']}"
        save_recording(cdr, @auth_token)
      end
    else
      $LOG.debug "skipping cdr #{cdr['id']}"
    end
  end
else
  $LOG.warn "Authentication failed unable to fetch messages"
  puts "no auth token..stopping"
end

