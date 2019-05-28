require 'thread'

Orchestrator::Testing.mock_device 'Cisco::CollaborationEndpoint::RoomOs',
                                  settings: {
                                      peripheral_id: 'MOCKED_ID',
                                      device_config: {
                                          Audio: {
                                              DefaultVolume: 100
                                          }
                                      }
                                  } do
    # Patch in some tracking of request UUID's so we can form and validate
    # device comms.
    @manager.instance.class_eval do
        generate_uuid = instance_method(:generate_request_uuid)

        attr_accessor :__request_ids

        define_method(:generate_request_uuid) do
            generate_uuid.bind(self).call.tap do |id|
                @__request_ids ||= Queue.new
                @__request_ids << id
            end
        end
    end

    def request_ids
        @manager.instance.__request_ids
    end

    def id_peek
        @last_id || request_ids.pop(true).tap { |id| @last_id = id }
    end

    def id_pop
        @last_id.tap { @last_id = nil } || request_ids.pop(true)
    end

    def section(message)
        puts "\n\n#{'-' * 80}"
        puts message
        puts "\n"
    end

    # -------------------------------------------------------------------------
    section 'Connection setup'

    transmit <<~BANNER
        Welcome to
        Cisco Codec Release Spark Room OS 2017-10-31 192c369
        SW Release Date: 2017-10-31
        *r Login successful

        OK

    BANNER

    expect(status[:connected]).to be true

    should_send "Echo off\n"
    responds "\e[?1034h\r\nOK\r\n"

    should_send "xPreferences OutputMode JSON\n"

    # -------------------------------------------------------------------------
    section 'System registration'

    should_send "xCommand Peripherals Connect ID: \"MOCKED_ID\" Name: \"ACAEngine\" Type: ControlSystem | resultId=\"#{id_peek}\"\n"
    responds(
        <<~JSON
            {
                "CommandResponse":{
                    "PeripheralsConnectResult":{
                        "status":"OK"
                    }
                },
                "ResultId": \"#{id_pop}\"
            }
        JSON
    )

    # -------------------------------------------------------------------------
    section 'Config push'

    should_send "xConfiguration Audio DefaultVolume: 100 | resultId=\"#{id_peek}\"\n"
    responds(
        <<~JSON
            {
                "ResultId": \"#{id_pop}\"
            }
        JSON
    )

    # -------------------------------------------------------------------------
    section 'Initial state sync'

    should_send "xFeedback register /Configuration | resultId=\"#{id_peek}\"\n"
    responds(
        <<~JSON
            {
                "ResultId": \"#{id_pop}\"
            }
        JSON
    )

    should_send "xConfiguration *\n"
    responds(
        <<~JSON
            {
              "Configuration":{
                "Audio":{
                  "DefaultVolume":{
                    "valueSpaceRef":"/Valuespace/INT_0_100",
                    "Value":"50"
                  },
                  "Input":{
                    "Line":[
                      {
                        "id":"1",
                        "VideoAssociation":{
                          "MuteOnInactiveVideo":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"On"
                          },
                          "VideoInputSource":{
                            "valueSpaceRef":"/Valuespace/TTPAR_PresentationSources_2",
                            "Value":"2"
                          }
                        }
                      }
                    ],
                    "Microphone":[
                      {
                        "id":"1",
                        "EchoControl":{
                          "Dereverberation":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"Off"
                          },
                          "Mode":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"On"
                          },
                          "NoiseReduction":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"On"
                          }
                        },
                        "Level":{
                          "valueSpaceRef":"/Valuespace/INT_0_24",
                          "Value":"14"
                        },
                        "Mode":{
                          "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                          "Value":"On"
                        }
                      },
                      {
                        "id":"2",
                        "EchoControl":{
                          "Dereverberation":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"Off"
                          },
                          "Mode":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"On"
                          },
                          "NoiseReduction":{
                            "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                            "Value":"On"
                          }
                        },
                        "Level":{
                          "valueSpaceRef":"/Valuespace/INT_0_24",
                          "Value":"14"
                        },
                        "Mode":{
                          "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                          "Value":"On"
                        }
                      }
                    ]
                  },
                  "Microphones":{
                    "Mute":{
                      "Enabled":{
                        "valueSpaceRef":"/Valuespace/TTPAR_MuteEnabled",
                        "Value":"True"
                      }
                    }
                  }
                }
              }
            }
        JSON
    )
    expect(status[:configuration].dig(:Audio, :Input, :Microphone, 1, :Mode)).to be true

    # -------------------------------------------------------------------------
    section 'Base comms (protected methods - ignore the access warnings)'

    # Append a request id and handle generic response parsing
    exec(:do_send, 'xCommand Standby Deactivate')
        .should_send("xCommand Standby Deactivate | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "StandbyDeactivateResult":{
                            "status":"OK"
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to be :success

    # Handle invalid device commands
    exec(:do_send, 'Not a real command')
        .should_send("Not a real command | resultId=\"#{id_pop}\"\n")
        .responds("Command not recognized.\r\n")
    expect { result }.to raise_error(Orchestrator::Error::CommandFailure)

    # Handle async response data
    exec(:do_send, 'xCommand Standby Deactivate')
        .should_send("xCommand Standby Deactivate | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "RandomAsyncData": "Foo"
                }
            JSON
        )
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "StandbyDeactivateResult":{
                            "status":"OK"
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to be :success

    # Device event subscription
    exec(:register_feedback, '/Status/Audio/Microphones/Mute')
        .should_send("xFeedback register /Status/Audio/Microphones/Mute | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to be :success

    # Bind module status to device state
    exec(:bind_feedback, '/Status/Audio/Volume', :volume)
        .should_send("xFeedback register /Status/Audio/Volume | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .responds(
            <<~JSON
                {
                    "Status":{
                        "Audio":{
                            "Volume":{
                                "Value":"50"
                            }
                        }
                    }
                }
            JSON
        )
    expect(status[:volume]).to be 50

    # Bind xStatus to module state
    exec(:bind_status, 'Standby State', :standby_state)
        .should_send("xFeedback register /Status/Standby/State | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .should_send("xStatus Standby State | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "Status":{
                        "Standby":{
                            "State":{
                                "Value":"HalfWake"
                            }
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .responds(
            <<~JSON
                {
                    "Status":{
                        "Standby":{
                            "State":{
                                "Value":"Standby"
                            }
                        }
                    }
                }
            JSON
        )
    expect(status[:standby_state]).to be true

    # -------------------------------------------------------------------------
    section 'Commands'

    # Basic command
    exec(:xcommand, 'Standby Deactivate')
        .should_send("xCommand Standby Deactivate | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "StandbyDeactivateResult":{
                            "status":"OK"
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to eq status: 'OK'

    # Command with arguments
    exec(:xcommand, 'Video Input SetMainVideoSource', ConnectorId: 1, Layout: :PIP)
        .should_send("xCommand Video Input SetMainVideoSource ConnectorId: 1 Layout: PIP | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "InputSetMainVideoSourceResult":{
                            "status":"OK"
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to eq status: 'OK'

    # Return device argument errors
    exec(:xcommand, 'Video Input SetMainVideoSource', ConnectorId: 1, SourceId: 1)
        .should_send("xCommand Video Input SetMainVideoSource ConnectorId: 1 SourceId: 1 | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "InputSetMainVideoSourceResult":{
                            "status":"Error",
                            "Reason":{
                                "Value":"Must supply either SourceId or ConnectorId (but not both.)"
                            }
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect { result }.to raise_error(Orchestrator::Error::CommandFailure)

    # Return error from invalid / inaccessable xCommands
    exec(:xcommand, 'Not A Real Command')
        .should_send("xCommand Not A Real Command | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "Result":{
                            "status":"Error",
                            "Reason":{
                                "Value":"Unknown command"
                            }
                        },
                        "XPath":{
                            "Value":"/Not/A/Real/Command"
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect { result }.to raise_error(Orchestrator::Error::CommandFailure)

    # Multiline commands
    exec(:xcommand, 'SystemUnit SignInBanner Set', "Hello\nWorld!")
        .should_send(
            <<~COMMAND
                xCommand SystemUnit SignInBanner Set | resultId=\"#{id_peek}\"
                Hello
                World!
                .
            COMMAND
        )
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "SignInBannerSetResult":{
                            "status":"OK"
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to eq status: 'OK'


    # -------------------------------------------------------------------------
    section 'Configuration'

    # Basic configuration
    exec(:xconfiguration, 'Video Input Connector 1', InputSourceType: :Camera)
        .should_send("xConfiguration Video Input Connector 1 InputSourceType: Camera | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to be :success

    # Multuple settings return a unit :success when all ok
    exec(:xconfiguration, 'Video Input Connector 1', InputSourceType: :Camera, Name: 'Borris', Quality: :Motion)
        .should_send("xConfiguration Video Input Connector 1 InputSourceType: Camera | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .should_send("xConfiguration Video Input Connector 1 Name: \"Borris\" | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .should_send("xConfiguration Video Input Connector 1 Quality: Motion | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to be :success

    # Multiple settings with failure with return a command failure
    exec(:xconfiguration, 'Video Input Connector 1', InputSourceType: :Camera, Foo: 'Bar', Quality: :Motion)
        .should_send("xConfiguration Video Input Connector 1 InputSourceType: Camera | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .should_send("xConfiguration Video Input Connector 1 Foo: \"Bar\" | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "CommandResponse":{
                        "Configuration":{
                            "status":"Error",
                            "Reason":{
                                "Value":"No match on address expression."
                            },
                            "XPath":{
                                "Value":"Configuration/Video/Input/Connector[1]/Foo"
                            }
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
        .should_send("xConfiguration Video Input Connector 1 Quality: Motion | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect { result }.to raise_error(Orchestrator::Error::CommandFailure)


    # -------------------------------------------------------------------------
    section 'Status'

    # Status query
    exec(:xstatus, 'Audio')
        .should_send("xStatus Audio | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "Status":{
                        "Audio":{
                            "Input":{
                                "Connectors":{
                                    "Microphone":[
                                        {
                                            "id":"1",
                                            "ConnectionStatus":{
                                                "Value":"Connected"
                                            }
                                        },
                                        {
                                            "id":"2",
                                            "ConnectionStatus":{
                                                "Value":"NotConnected"
                                            }
                                        }
                                    ]
                                }
                            },
                            "Microphones":{
                                "Mute":{
                                    "Value":"On"
                                }
                            },
                            "Output":{
                                "Connectors":{
                                    "Line":[
                                        {
                                            "id":"1",
                                            "DelayMs":{
                                                "Value":"0"
                                            }
                                        }
                                    ]
                                }
                            },
                            "Volume":{
                                "Value":"50"
                            }
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )

    # Status results are provided in the return
    exec(:xstatus, 'Time')
        .should_send("xStatus Time | resultId=\"#{id_peek}\"\n")
        .responds(
            <<~JSON
                {
                    "Status":{
                        "Time":{
                            "SystemTime":{
                                "Value":"2017-11-27T15:14:25+1000"
                            }
                        }
                    },
                    "ResultId": \"#{id_pop}\"
                }
            JSON
        )
    expect(result).to eq SystemTime: '2017-11-27T15:14:25+1000'
end
