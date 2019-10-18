# frozen_string_literal: true

# Documentation: https://docs.google.com/document/d/18EjSfVSg5FTe0rMsc-Yygb8obcOp7tm5BNmz9OGj21o/edit?usp=sharing

require 'net/http'
require 'json'

module Mediasite; end

class Mediasite::Module
    include ::Orchestrator::Constants

    descriptive_name 'Mediasite Recorder'
    generic_name :Capture
    implements :logic

    default_settings(
        # url: 'https://alex-dev.deakin.edu.au/Mediasite/' # api url endpoint
        # username:
        # password:
        # api_key: # sfapikey
        # actual_room_name: setting to override room name to search when they mediasite room names don't match up wtih backoffice system names
        # recorder_id: # set recorder id manually if needed
        update_every: 5 # number of seconds to poll recorder state
    )

    def on_load
        on_update
    end

    def on_update
        schedule.clear
        self[:room_name] = room_name
        self[:device_id] = get_device_id
        poll
    end

    def room_name
        setting(:actual_room_name) || system.name
    end

    def poll
        state
        schedule.every("#{setting(:update_every)}s") do
            state
        end
    end

    def get_request(url)
        req_url = url
        logger.debug(req_url)
        
        task {
            uri = URI(req_url)
            req = Net::HTTP::Get.new(uri)
            req.basic_auth(setting(:username), setting(:password))
            req['sfapikey'] = setting(:api_key)
            http = Net::HTTP.new(uri.hostname, uri.port)
            http.use_ssl = true
            JSON.parse(http.request(req).body)
        }.value
    end

    def post_request(url)
        req_url = setting(:url) + url
        
        task {
            uri = URI(req_url)
            req = Net::HTTP::Post.new(uri)
            req.basic_auth(setting(:username), setting(:password))
            req['sfapikey'] = setting(:api_key)
            http = Net::HTTP.new(uri.hostname, uri.port)
            http.use_ssl = true
            http.request(req)
        }.value
        :success
    end

    def create_url(url)
        setting(:url) + url
    end

    def get_device_id
        # Use $top=1000 to ensure that all rooms are returned from the api
        device_id = ''
        if setting(:recorder_id)
            device_id = setting(:recorder_id)
        else
            res = get_request(create_url('/api/v1/Rooms?$top=1000'))
            res['value'].each { |room|
                if room['Name'] == room_name
                    device_id = room['DeviceConfigurations'][0]['DeviceId']
                    break
                end
            }
        end
        device_id
    end

    # State tracking of recording appliance. While there are numerous recorder states (currently 11 different states), we wish to present these as a simplified state set: Offline, Idle, Recording, Paused.
    STATES = {
        'Unknown' => 'offline',
        'Idle' => 'stop',
        'Busy' => 'offline',
        'RecordStart' => 'active',
        'Recording' => 'active',
        'RecordEnd' => 'active',
        'Pausing' => 'paused',
        'Paused' => 'paused',
        'Resuming' => 'active',
        'OpeningSession' => 'active',
        'ConfiguringDevices' => 'offline'
    }.freeze

    def state
        res = get_request(create_url("/api/v1/Recorders('#{self[:device_id]}')/Status"))
        self[:previous_state] = self[:state]
        self[:state] = res['RecorderState']

        if STATES[self[:state]] == 'active' || STATES[self[:state]] == 'paused'
          self[:current] = {
              'state' => STATES[self[:state]],
              'start_time' => ''
          }
        else
          self[:current] = nil
        end

        res = get_request(create_url("/api/v1/Recorders('#{self[:device_id]}')/CurrentPresentationMetadata"))
        self[:title] = res['Title']
        self[:presenters] = res['Presenters']

        # TODO: found out how to know if recording is being live streamed
        self[:live] = live?

        res = get_request(create_url("/api/v1/Recorders('#{self[:device_id]}')/ActiveInputs"))
        self[:dual] = res['ActiveInputs'].size >= 2 if res['ActiveInputs']

        res = get_request(create_url("/api/v1/Recorders('#{self[:device_id]}')/TimeRemaining"))
        self[:time_remaining] = res['SecondsRemaining']

        self[:volume] = 0 # TODO:
    end

    def live?
      live = self[:state] == 'Recording'
      res = get_request(create_url("/api/v1/Recorders('#{self[:device_id]}')/ScheduledRecordingTimes"))
      res['value'].each do |schedule|
          current_time = ActiveSupport::TimeZone.new('UTC').now
          start_time = ActiveSupport::TimeZone.new('UTC').parse(schedule['StartTime'])
          end_time = ActiveSupport::TimeZone.new('UTC').parse(schedule['EndTime'])
          if start_time <= current_time && current_time <= end_time
              presentation = get_request(schedule['ScheduleLink'] + '/Presentations')
              live = presentation['value'][0]['Status'] == 'Live'
              break
          end
      end
      live
    end

    def start
        post_request("/api/v1/Recorders('#{self[:device_id]}')/Start")
        state
    end

    def pause
        post_request("/api/v1/Recorders('#{self[:device_id]}')/Pause")
        state
    end

    def resume
        post_request("/api/v1/Recorders('#{self[:device_id]}')/Resume")
        state
    end

    def stop
        post_request("/api/v1/Recorders('#{self[:device_id]}')/Stop")
        state
    end
end
