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

    Dir.mkdir(@conffile['destination_dir']) unless Dir.exist?(@conffile['destination_dir'])
    Dir.mkdir('db/') unless Dir.exist?("db/")
    Dir.mkdir('logs/') unless Dir.exist?("logs/")
    Dir.mkdir(@conffile['cdrdir']) unless Dir.exist?(@conffile['cdrdir'])

    logfile = "logs/#{@conffile['logfile']}"
    logfilerotation = (@conffile['logfilerotation']).to_s

    @write_cdrs = @conffile['write_cdrs_to_file']
    @write_recs = @conffile['download_recordings']

    $LOG = Logger.new(logfile, logfilerotation)
    $LOG.level =  Logger::DEBUG
  end

  def init_start_time
    if File.exist?(File.join('db', 'cdrids'))
      $LOG.debug "db exists using short interval"
      t = (Time.now - (@conffile['sync_days'].to_i * 86400)).strftime("%d-%m-%Y")
    else
      $LOG.debug "db doesnt exist using long interval"
      t = (Time.now - (@conffile['initial_sync_days'].to_i * 86400)).strftime("%d-%m-%Y")
    end
    return t
  end

  def init_end_time
    Time.now.strftime("%d-%m-%Y")
  end

  def auth
    body = { username: @conffile['acct_username'], password:  @conffile['acct_password'] }

    response = HTTParty.post("#{@conffile['portal_url']}/auth/token",
      body: body.to_json,
      timeout: 10,
      headers: { 'Content-Type' => 'application/json' },
      verify: false )
    return response
  end

  ## Helper method returning http headers
  def request_headers(token)
    { 'Content-Type' => "application/json", 'Authorization' => token }
  end

  ## fetch array of CDRs to process
  def fetch_cdrs(token)
    $LOG.warn "Fetching CDRs from #{init_start_time} to #{init_end_time}"
    url = "#{@conffile['portal_url']}/cdrs?getAll=true&startDate=#{init_start_time}&endDate=#{init_end_time}"
    response = HTTParty.get(url,
      timeout: 10,
      headers: request_headers(token),
      verify: false )
    return response
  end

  ## Returns array of processed call id's 
  def call_ids
    dbfile = File.join('db','cdrids')
    @callids ||= File.open(dbfile, 'r').readlines.map(&:chomp) 
  end

  ## Checks if provided call hash has already been processed returns boolean to process it
  def check_cdr_id(call)
    dbfile = File.join('db','cdrids')
    result = true
    if File.exists?(dbfile)
      $LOG.debug "Checking id #{call['id']}"
      if call_ids.include?(call['id'])
        result = false
      else
        File.open(dbfile, 'a') { |f| f.write("#{call['id']}\n") }
      end
    else
      File.open(dbfile, 'a') { |f| f.write("#{call['id']}\n") }
    end
    return result
  end

  ## Returns array of processed recording call ids 
  def recorded_ids
    dbfile = File.join('db','recorded_ids')
    @recordedids ||= File.open(dbfile, 'r').readlines.map(&:chomp) 
  end

  ## Checks if procided callID has already had its recording processed
  def check_recording(call)
    dbfile = File.join('db','recorded_ids')
    result = true
    if File.exists?(dbfile)
      $LOG.debug "Checking recording id #{call['id']}"
      if recorded_ids.include?(call['id'])
        result = false
      end
    end
    return result
  end

  ##Returns boolean on if CDR bears a recording
  def cdr_recorded?(call)
    recorded = false
    if !call['recording_key'].nil? && call['recording_key'].length > 0
      recorded = true
    end
    return recorded
  end

  ## Helper method for cdr files
  def cdr_filename(call)
    File.join(@conffile['cdrdir'], "#{call['start_time'].split(' ').first}.csv")
  end

  ## Create cdr file if not exists 
  def cdr_file(call)
    file_headers = "id,responsible_party,start_time,hangup_cause,calling_party,called_party,caller_id_number,caller_id_name,duration,bill_duration,direction,mailbox,aleg_holdtime,bleg_holdtime,recorded,tags\n"
    unless File.exists?(cdr_filename(call))
      File.open(cdr_filename(call), 'a') {|f| f.write(file_headers) }
    end
  end
  
  ## Writes CDR to recording file
  def write_cdr(call)
    cdr_file(call)
    call_line = "\"#{call['id']}\",\"#{call['responsible_party']}\",\"#{call['start_time']}\",\"#{call['hangup_cause']}\",\"#{call['calling_party']}\",\"#{call['called_party']}\",\"#{call['caller_id_number']}\",\"#{call['caller_id_name']}\",\"#{call['duration']}\",\"#{call['bill_duration']}\",\"#{call['direction']}\",\"#{call['mailbox']}\",\"#{call['aleg_holdtime']}\",\"#{call['bleg_holdtime']}\",\"#{cdr_recorded?(call).to_s}\",\"#{call['tags']}\"\n"
    File.open(cdr_filename(call), 'a') {|f| f.write(call_line) }
  end

  ## Filename generator for recording file given CDR hash
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

  ## Fetch recording for given CDR
  def fetch_recording(call, token)
    url = "#{@conffile['portal_url']}/cdrs/#{call['id']}/recording"
    response = HTTParty.get(url,
      :timeout => 60,
      :headers => request_headers(token),
      :verify => false )
    return response
  end

  ## Save recording file and update DB if successful
  def save_recording(call, token)
    dbfile = File.join('db','recorded_ids')
    $LOG.warn "Processing recording for #{call['id']}"
    recording_file = fetch_recording(call, token)
    $LOG.warn "Retrieved #{recording_file.code}"
    if recording_file.code == 200
      File.open(File.join(@conffile['destination_dir'], file_name(call)), 'wb') { |f| f.write(recording_file.body) }
      File.open(dbfile, 'a') { |f| f.write("#{call['id']}\n") }
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
  $LOG.debug "received auth token. Good to proceed"
  $LOG.warn "Performing cdr fetch operation"

  cdrs = fetch_cdrs(@auth_token).parsed_response
  cdrs.sort_by { |c| c['id'] }.each do |cdr|
    if check_cdr_id(cdr)
      write_cdr(cdr) if @write_cdrs
      $LOG.debug "writing cdr #{cdr['id']}"
    else
      $LOG.debug "skipping cdr #{cdr['id']}"
    end
    if @write_recs && cdr_recorded?(cdr) && check_recording(cdr)
      $LOG.debug "Fetching recording for #{cdr['id']}"
      save_recording(cdr, @auth_token)
    end
  end
else
  $LOG.warn "Authentication failed unable to fetch messages"
  puts "no auth token..stopping"
end

