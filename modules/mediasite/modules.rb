# frozen_string_literal: true

require 'net/http'

module Mediasite; end

class Mediasite::Module
    descriptive_name 'Mediasite'
    generic_name :Recorder
    implements :logic

    default_settings(
        url: 'https://alex-dev.deakin.edu.au/Mediasite/',
        username: 'acaprojects',
        password: 'WtjtvB439cXdZ4Z3',
        update_every: 1
        # actual_room_name: setting to override room name to search when they mediasite room names don't match up wtih backoffice system names
    )

    def on_load
        on_update
    end

    def on_update
        schedule.clear
        self[:room_name] = setting(:actual_room_name) || ''
    end

    def start
        schedule.every("#{setting(:update_every)}m") do
            state
        end
    end

    def get_request(url)
        uri = URI.parse(url)
        request = Net::HTTP::GET.new(URI.parse(uri))
        request.basic_auth(setting(:username), setting(:password))
        http = Net::HTTP.new(uri.host, uri.port)
        http.request(request)
    end

    def post_request(url)
        uri = URI.parse(url)
        request = Net::HTTP::POST.new(URI.parse(uri))
        request.basic_auth(setting(:username), setting(:password))
        http = Net::HTTP.new(uri.host, uri.port)
        http.request(request)
    end

    # https://alex.deakin.edu.au/mediasite/api/v1/$metadata#Rooms
    # GET /api/v1/Room
    # GET /api/v1/Rooms('id')
    def get_rooms
        get_request(url + '/api/v1/Room')
    end


    # State tracking of recording appliance. While there are numerous recorder states (currently 11 different states), we wish to present these as a simplified state set: Offline, Idle, Recording, Paused.
    STATES = {
        'Unknown' => 'Offline',
        'Idle' => 'Idle',
        'Busy' => 'Recording',
        'RecordStart' => 'Recording',
        'Recording' => 'Recording',
        'RecordEnd' => 'Recording',
        'Pausing' => 'Recording',
        'Paused' => 'Recording',
        'Resuming' => 'Recording',
        'OpeningSession' => 'Recording',
        'ConfiguringDevices' => 'Idle'
    }.freeze

    # GET /api/v1/Recorders('id')/Status
    def state(id)
        response = request(url + "/api/v1/Recorders('#{id}')/Status")
        self[:previous_state] = self[:state]
        self[:state] = STATES[response]
    end

=begin
POST /api/v1/CatchDevices('id')/Start
POST /api/v1/CatchDevices('id')/Stop
POST /api/v1/CatchDevices('id')/Pause
POST /api/v1/CatchDevices('id')/Resume

POST /api/v1/Recorders('id')/Start
POST /api/v1/Recorders('id')/Stop
POST /api/v1/Recorders('id')/Pause
POST /api/v1/Recorders('id')/Resume
=end
    def pause
    end

    def resume
    end

    def stop
    end
end
