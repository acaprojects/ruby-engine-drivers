module SmartTech; end
# Copyright Deakin University, 2018
# Documentation: http://www.smarttech.com/en/kb/171164
# Panel requires 19200,8,N,1

class SmartTech::SmartBoard
 include ::Orchestrator::Constants
 include ::Orchestrator::Transcoder

 # Discovery Information
 implements :device
 descriptive_name 'Smart Board 7000'
 generic_name :Display

 # Communication settings
# tokenize delimiter: "\x0D"  #Other SMARTboard docs (for different models) specify CR.  Docs for 7000 does not specify.
 delay between_sends: 300
 wait_response timeout: 5000, retries: 3

 #The SMARTboard allows for multiple panels daisy-chained.  This driver assumes it is controlling one panel only.
 #Panel uses 19200,8,N,1.  When passing through another device for IP->RS232 transport (e.g. Atlona OmniStream or AMX SVSi decoder), make sure
 #the transport device has its serial port configured correctly.

 #The SMARTboard has numerous power states: ON, READY, STANDBY, POWERSAVE, UPDATEON, UPDATEREADY
 #This driver uses ON and READY.  Other states may caus the NIC to drop offline.
 #Changes in power state must go via the ON state.  I.e.  The SMARTboard will not change from STANDBY to POWERSAVE, etc.

 #Real world tests were performed with panel fw v2.0.134.0.  Some observations:
 # - The panel will sometimes drop space characters before processing the command.  This causes the panels command parsing to reject the command.
 # - The panel Rx buffer can be flodded with commands.  Subsequent commands will be queueued then processed either as seperate commands or one "large corrupt command".
 # - Rx buffer overflow can cause the panel comms to lock up, requiring a hard power-cycle of the panel.

 def on_load
 end

 def on_unload
 end

 def on_update
  @previous_volume_level ||= 40
  serial?
  firmware?
  partnumber?
#  self[:off_level] = "ignore this"  #deprecated.
 end

 def connected
  do_poll
  serial?
  firmware?
  partnumber?

  schedule.every('10s') do
   do_poll
  end
 end

 def disconnected
  schedule.clear
 end


 def power(options = {}, state)  #20180927 - Added the options parameter to the function parameters.
  if is_affirmative?(self[:firmware_updating])
   logger.debug {"-- Smart Board panel is updating firmware.  Power(#{state}) request ignored."}
  else
   state = is_affirmative?(state)
   self[:power_target] = state
   power? do
    options[:name] = :set_power  #Name the message so it overrides other messages of the same name.
    options[:priority] = 20
    if state && !self[:power]  #If we want ON and power is not ON
     do_send("set powerstate=on",options)
    elsif !state && self[:power]  #If we want OFF and power is ON
     do_send("set powerstate=ready",options)
    end
   end
  end
 end

 def power?(options = {}, &block)
  options[:emit] = block unless block.nil?
  options[:name] = :power_query
  if !options.include?(:priority)
   options[:priority] = 5
  end
  do_send("get powerstate", options)
 end


 def volume(level)
  @previous_volume_level = self[:volume] = level
  do_send("set volume=#{level}")
 end
 def volume?(options = {}, &block)
  options[:emit] = block unless block.nil?
  options[:name] = :get_volume
  options[:priority] = 5
  do_send("get volume", options)
 end

 # Audio mute
 def mute_audio(state = true)
  level = if is_affirmative?(state)
   0
  elsif @previous_volume_level == 0
   30
  else
   @previous_volume_level
  end
  volume(level)
 end
 alias_method :mute, :mute_audio

 def unmute_audio
  mute_audio(false)
 end
 alias_method :unmute, :unmute_audio

 def video_freeze(state)
  state = is_affirmative?(state)
  if state
   do_send("set videofreeze=on",:priority => 20)
  else
   do_send("set videofreeze=off",:priority => 20)
  end
 end
 def video_freeze?(options = {}, &block)
  options[:emit] = block unless block.nil?
  options[:name] = :get_volume
  options[:priority] = 5
  do_send("get videofreeze", options)
 end

 def serial?(options = {}, &block)
  options[:emit] = block unless block.nil?
  options[:name] = :get_serial
  options[:priority] = 15
  do_send("get serialnum", options)
 end
 def firmware?(options = {}, &block)
  options[:emit] = block unless block.nil?
  options[:name] = :get_firmware
  options[:priority] = 16
  do_send("get fwversion", options)
 end
 def partnumber?(options = {}, &block)
  options[:emit] = block unless block.nil?
  options[:name] = :get_partnum
  options[:priority] = 17
  do_send("get partnum", options)
 end

 #
 # Input selection
 #
 INPUTS = {
  :hdmi  => 'hdmi1',
  :hdmi2 => 'hdmi2',
  :dp    => 'dp1',
  :vga   => 'vga1',
  :ops   => 'ops1'  #whiteboard
 }
 # INPUTS.merge!(INPUTS.invert)

 def switch_to(input)
   input = input.to_sym
   return unless INPUTS.has_key? input

   do_send("set input=#{INPUTS[input]}")
   logger.debug {"-- Told SMARTboard to switch to input: #{input}"}
 end
 def input?(options = {}, &block)
  options[:name] = :get_input
  options[:priority] = 5
  do_send("get input", options)
 end

 def received(data, resolve, command)
  logger.debug "SMARTboard sent: #{data}"

  #Get requests are formatted as: get<space><param>
  #Set requests are formatted as: set<space><param>=<value>
  #Responses to both are formatted as: <param>=<value>
  #Responses to bad commands are formatted as: invalid cmd=<bad command>
  #Commands/updates initiated from the panel are prepended with '#'
  #Replies from the panel are wrapped with \r\n and \r\n> (telnet prompt).  We strip these before parsing actual reply.
  data = data.strip  #Remove outer whitespace (only front with our data)
  data.gsub!("\r\n>",'')  #Remove trailing whitespace and prompt

  panelInitiated = (data[0] == '#')  #Check for user-initiated commands.
  if panelInitiated
   data = data[1..-1]  #Drop the leading '#'.
  end

  data = data.split(/=/)  #Split the response on the '=' character.
#  logger.debug "PostSplit: #{data}"

  case data[0].to_sym
   when :powerstate
#    if panelInitiated
#     logger.debug "I see what you did there."  #This works, and is left here as a demo of how to determine what triggered the reply.
#    end

    #If data[1] contains "UPDATE", fw update is in progress.  This can occure regardless of on/off state, so we track power and fwupdate independently.
    #We store the states as boolean values since the power() function uses boolean logic when deciding whether to send ON/OFF commands.
    case data[1].to_sym
     when :on, :updateon
      self[:power] = true
     when :ready, :standby, :powersave, :updateready
      self[:power] = false
     else
      self[:power] = :unknown
    end
    case data[1].to_sym
     when :updateon, :updateready
      self[:firmware_updating] = true
     when :on, :ready, :standby, :powersave
      self[:firmware_updating] = false
     else
      self[:firmware_updating] = :unknown
    end
    #end of powerstate parsing

   when :input
    self[:input] = data[1]
   when :volume
    vol = self[:volume] = data[1].to_i
    self[:mute] = vol == 0
   when :videofreeze
    case data[1].to_sym
     when :on
      self[:video_freeze] = true
     when :off
      self[:video_freeze] = false
     end

   when :serialnum
    self[:serial] = data[1]
   when :fwversion
    self[:firmware] = data[1]
   when :partnum
    self[:partnumber] = data[1]

   when :"invalid cmd"
    logger.debug "ACA SMARTboard driver does not understand that response.  Sad face."
  end  #end of case

  return :success
 end

private

 def do_poll
  power?(:priority => 0) do
   if self[:power] == true
    video_freeze?
    input?
   end
  end
 end

 def do_send(command, options = {})
  logger.debug "requesting #{command}"
  command = "#{command}\r"
  send(command, options)
 end
end
