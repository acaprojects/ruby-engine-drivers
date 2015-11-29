MODULE_NAME='Clock_Audio_CDT100_Module'(DEV vdvDevice, DEV dvDevice)
 
(***********************************************************)
(*          DEVICE NUMBER DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_DEVICE

dvdDevice = DYNAMIC_VIRTUAL_DEVICE
dvMaster 	= 0:1:0

#INCLUDE 'SNAPI'

(***********************************************************)
(*               CONSTANT DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_CONSTANT

/////////////////////////////////////////////////////////////
// MAX STUFF
/////////////////////////////////////////////////////////////

MAX_CHANNELS					= 4
MAX_IP_ADDRESS				= 15
MAX_DATA_TOTAL				=	1000
MAX_DATA_ITEM					= 100
MAX_QUEUE							= 10000
MAX_BUFFER						= 10000
MAX_FAILED_RSP				= 3

/////////////////////////////////////////////////////////////
// UDP STUFF
/////////////////////////////////////////////////////////////

UDP_LOCAL_PORT_BASE		= 50000

/////////////////////////////////////////////////////////////
// COMM API STUFF
/////////////////////////////////////////////////////////////

BTN_INPUT_EVENT				= 1

CHAN_LED_RED					= 1
CHAN_LED_GREEN				= 2
CHAN_ARM_C						= 3
CHAN_PHANTOM					= 4
CHAN_PRESET_SAVE			= 5
CHAN_PRESET_LOAD			= 6

/////////////////////////////////////////////////////////////
// STATE STUFF
/////////////////////////////////////////////////////////////

STATE_OFF							= 0
STATE_ON							= 1

/////////////////////////////////////////////////////////////
// MODULE COMMANDS
/////////////////////////////////////////////////////////////

MOD_SEPERATOR					= ','
MOD_SET_PROPERTY			= 'PROPERTY-'
MOD_KEY_IP_ADDRESS 		=	'IP_ADDRESS'
MOD_KEY_IP_PORT				=	'IP_PORT'
MOD_KEY_SW_ADDRESS		= 'SWITCH_ADDRESS'
MOD_KEY_PRESET_SAVED	= 'PRESET_SAVED'
MOD_PASSTHRU					=	'PASSTHRU-'
MOD_REINIT						=	'REINIT'
MOD_DEBUG							=	'DEBUG-'

/////////////////////////////////////////////////////////////
// DEVICE COMMANDS
/////////////////////////////////////////////////////////////

DEV_CMD_DELIM[1]			= {$0D}
DEV_CMD_SEPERATOR			= ' '
DEV_CMD_SET_PHANTOM		= 'PP'
DEV_CMD_QUERY					= 'QUERY'
DEV_CMD_SET_CH32			= 'SCH32'
DEV_CMD_GET_CH32			= 'GCH32'
DEV_CMD_SET_ARM_C			= 'SARMC'
DEV_CMD_GET_ARM_C			= 'GARMC'
DEV_CMD_VERSION				= 'VERSION'
DEV_CMD_ASYNC					= 'SASIP'
DEV_CMD_INPUT_STATUS	= 'BSTATUS'
DEV_CMD_LED_RED				= 'R='
DEV_CMD_LED_GREEN			= 'G='
DEV_CMD_INPUT					= 'SC='
DEV_CMD_ID						= 'ID='
DEV_CMD_ADDRESS				= 'GAS'
DEV_CMD_PRESET_SAVE		= 'SAVE'
DEV_CMD_PRESET_LOAD		= 'LOAD'

/////////////////////////////////////////////////////////////
// DEVICE RESPONSES
/////////////////////////////////////////////////////////////

DEV_RSP_DELIM[2]			= {$0D,$00}
DEV_RSP_ACK						= 'ACK'
DEV_RSP_NACK					= 'NACK'

/////////////////////////////////////////////////////////////
// TIMELINE STUFF
/////////////////////////////////////////////////////////////

TL_HEARTBEAT					= 11
TL_RESPONSE						= 12

/////////////////////////////////////////////////////////////
// DEBUG STUFF
/////////////////////////////////////////////////////////////

DEBUG_ERROR						= 1
DEBUG_WARNING					= 2
DEBUG_DEBUG						= 3
DEBUG_INFO						= 4

(***********************************************************)
(*              DATA TYPE DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_TYPE

(***********************************************************)
(*               VARIABLE DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_VARIABLE

/////////////////////////////////////////////////////////////
// DEVICE INFO
/////////////////////////////////////////////////////////////

VOLATILE DEV vdvDevices[MAX_CHANNELS]
VOLATILE DEV dvdDevices[MAX_CHANNELS]
VOLATILE INTEGER nRedLedState[MAX_CHANNELS]
VOLATILE INTEGER nGreenLedState[MAX_CHANNELS]
VOLATILE INTEGER nInputState[MAX_CHANNELS]
VOLATILE INTEGER nPhantomState[MAX_CHANNELS]
VOLATILE INTEGER nArmCState
VOLATILE CHAR sSwitchAddress[MAX_DATA_ITEM]

/////////////////////////////////////////////////////////////
// UDP SETUP
/////////////////////////////////////////////////////////////

VOLATILE CHAR sAddress[MAX_IP_ADDRESS]
VOLATILE INTEGER nPort
VOLATILE INTEGER nLocalPort
VOLATILE IP_ADDRESS_STRUCT uLocalIPAdress

/////////////////////////////////////////////////////////////
// QUEUE STUFF
/////////////////////////////////////////////////////////////

VOLATILE CHAR sQueue[MAX_QUEUE]
VOLATILE CHAR bQueueLocked

/////////////////////////////////////////////////////////////
// BUFFER STUFF
/////////////////////////////////////////////////////////////

VOLATILE CHAR sBuffer[MAX_BUFFER]

/////////////////////////////////////////////////////////////
// HEARTBEAT STUFF
/////////////////////////////////////////////////////////////

VOLATILE LONG lTlHeartbeat[] = {30000}
VOLATILE CHAR bLastOutWasHeartbeat

/////////////////////////////////////////////////////////////
// RESPONSE TIMER STUFF
/////////////////////////////////////////////////////////////

VOLATILE LONG lTlResponse[] = {2000}
VOLATILE INTEGER nFailedResponseCount

/////////////////////////////////////////////////////////////
// INIT STUFF
/////////////////////////////////////////////////////////////

VOLATILE CHAR bInitializing

/////////////////////////////////////////////////////////////
// DEBUG STUFF
/////////////////////////////////////////////////////////////

VOLATILE INTEGER nDebugState = DEBUG_ERROR

/////////////////////////////////////////////////////////////
// CHANNEL FEEDBACK STUFF
/////////////////////////////////////////////////////////////

VOLATILE LONG lTlFeedback[] = {300}

(***********************************************************)
(*        SUBROUTINE/FUNCTION DEFINITIONS GO BELOW         *)
(***********************************************************)

/////////////////////////////////////////////////////////////
// MODULE SETUP
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION SETUP_VIRTUAL_DEVICE_PORTS(DEV vdvVirtual[], DEV dvdDynamic[])
{
	STACK_VAR INTEGER nLoop
	
	SET_VIRTUAL_PORT_COUNT(vdvDevice, MAX_CHANNELS)
	SET_VIRTUAL_PORT_COUNT(dvdDevice, MAX_CHANNELS)
	
	FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
	{
		SET_LENGTH_ARRAY(vdvVirtual, LENGTH_ARRAY(vdvVirtual) + 1)
		SET_LENGTH_ARRAY(dvdDynamic, LENGTH_ARRAY(dvdDynamic) + 1)
		
		vdvVirtual[nLoop].NUMBER = vdvDevice.NUMBER
		dvdDynamic[nLoop].NUMBER = dvdDevice.NUMBER
		
		vdvVirtual[nLoop].PORT	 = nLoop
		dvdDynamic[nLoop].PORT	 = nLoop
		
		vdvVirtual[nLoop].SYSTEM = vdvDevice.SYSTEM
		dvdDynamic[nLoop].SYSTEM = dvdDevice.SYSTEM
		
		TRANSLATE_DEVICE(vdvVirtual[nLoop], dvdDynamic[nLoop])
	}
	
	REBUILD_EVENT()
}

/////////////////////////////////////////////////////////////
// COMMAND PARSING
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION CHAR[MAX_DATA_ITEM] PARSE_CMD_HEADER(CHAR sCmd[])
{
	STACK_VAR CHAR sTemp[MAX_DATA_ITEM]
	sTemp = sCmd
	
	IF(FIND_STRING(sTemp, '-', 1))
	{
		sTemp = REMOVE_STRING(sCmd, '-', 1)
	}
	ELSE
	{
		sTemp = sCmd
		sCmd = ""
	}

	RETURN sTemp
}

DEFINE_FUNCTION CHAR[MAX_DATA_ITEM] PARSE_CMD_KEY(CHAR sCmd[])
{
	STACK_VAR CHAR sTemp[MAX_DATA_ITEM]
	sTemp = sCmd
	
	IF(FIND_STRING(sTemp, MOD_SEPERATOR, 1))
	{
		sTemp = REMOVE_STRING(sCmd, MOD_SEPERATOR, 1)
		SET_LENGTH_STRING(sTemp, LENGTH_STRING(sTemp) - 1)
	}
	ELSE
	{
		sCmd = ""
		sTemp = sCmd
	}

	RETURN sTemp
}

/////////////////////////////////////////////////////////////
// QUEUE STUFF
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION CHAR QUEUE_HAS_ITEMS()
{
	RETURN LENGTH_STRING(sQueue) > 0
}

DEFINE_FUNCTION ENQUEUE(CHAR sQueue[], CHAR sMsg[])
{
	STACK_VAR CHAR bIsEmpty
	
	bIsEmpty = QUEUE_HAS_ITEMS() == 0
	
	sQueue = "sQueue, sMsg, DEV_CMD_DELIM"
	
	IF(bIsEmpty == TRUE)
	{
		DEQUEUE()
	}
}

DEFINE_FUNCTION DEQUEUE()
{
	STACK_VAR CHAR sTemp[MAX_DATA_TOTAL]

	IF(bQueueLocked == FALSE)
	{
		IF(QUEUE_HAS_ITEMS())
		{
			sTemp = REMOVE_STRING(sQueue, DEV_CMD_DELIM, 1)
			
			IF(FIND_STRING(sTemp, DEV_CMD_VERSION, 1))
			{
				ON[bLastOutWasHeartbeat]
				START_HEARTBEAT_TIMER()
			}
			ELSE
			{
				OFF[bLastOutWasHeartbeat]
			}
			
			SEND_STRING dvDevice, "sTemp"
			DEBUG(DEBUG_INFO, "'STRING TO DEVICE: ', sTemp")
			
			ON[bQueueLocked]
			START_RESPONSE_TIMER()
		}
	}
}

/////////////////////////////////////////////////////////////
// ASYNC FEEDBACK
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION START_ASYNC()
{
	IF(LENGTH_STRING(sAddress) == 15 && nLocalPort > UDP_LOCAL_PORT_BASE)
	{
		ENQUEUE(sQueue, "DEV_CMD_ASYNC, DEV_CMD_SEPERATOR, uLocalIPAdress.IPAddress, ':', ITOA(nLocalPort)")
	}
}

/////////////////////////////////////////////////////////////
// COMMAND PROCESSING
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION UPDATE_STATE(INTEGER nPort, INTEGER nType, INTEGER nState)
{
	IF(nState == STATE_OFF || nState == STATE_ON)
	{
		SWITCH(nType)
		{
			CASE CHAN_LED_RED:
			{
				SELECT
				{
					ACTIVE(nPort > 0 && nPort <= MAX_CHANNELS):
					{
						ENQUEUE(sQueue, "DEV_CMD_SET_CH32, DEV_CMD_SEPERATOR, ITOA(nPort), DEV_CMD_SEPERATOR, DEV_CMD_LED_RED, ITOA(nState)")
					}
					ACTIVE(nPort == 0):
					{
						STACK_VAR INTEGER nLoop
						
						FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
						{
							ENQUEUE(sQueue, "DEV_CMD_SET_CH32, DEV_CMD_SEPERATOR, ITOA(nLoop), DEV_CMD_SEPERATOR, DEV_CMD_LED_RED, ITOA(nState)")
						}
					}
				}
			}
			CASE CHAN_LED_GREEN:
			{
				SELECT
				{
					ACTIVE(nPort > 0 && nPort <= MAX_CHANNELS):
					{
						ENQUEUE(sQueue, "DEV_CMD_SET_CH32, DEV_CMD_SEPERATOR, ITOA(nPort), DEV_CMD_SEPERATOR, DEV_CMD_LED_GREEN, ITOA(nState)")
					}
					ACTIVE(nPort == 0):
					{
						STACK_VAR INTEGER nLoop
						
						FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
						{
							ENQUEUE(sQueue, "DEV_CMD_SET_CH32, DEV_CMD_SEPERATOR, ITOA(nLoop), DEV_CMD_SEPERATOR, DEV_CMD_LED_GREEN, ITOA(nState)")
						}
					}
				}
			}
			CASE CHAN_PHANTOM:
			{
				SELECT
				{
					ACTIVE(nPort > 0 && nPort <= MAX_CHANNELS):
					{
						ENQUEUE(sQueue, "DEV_CMD_SET_PHANTOM, DEV_CMD_SEPERATOR, ITOA(nPort), DEV_CMD_SEPERATOR, ITOA(nState)")
					}
					ACTIVE(nPort == 0):
					{
						STACK_VAR INTEGER nLoop
						
						FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
						{
							ENQUEUE(sQueue, "DEV_CMD_SET_PHANTOM, DEV_CMD_SEPERATOR, ITOA(nLoop), DEV_CMD_SEPERATOR, ITOA(nState)")
						}
					}
				}
			}
			CASE CHAN_ARM_C:
			{
				IF(nPort == 1)
				{
					ENQUEUE(sQueue, "DEV_CMD_SET_ARM_C, DEV_CMD_SEPERATOR, ITOA(nState)")
				}
			}
		}
	}
}

// ONLY PRESET 0 IS AVAILABLE AT THIS POINT IN TIME
DEFINE_FUNCTION PRESET_SAVE()
{
	ENQUEUE(sQueue, "DEV_CMD_PRESET_SAVE, DEV_CMD_SEPERATOR, '0'")
}

// ONLY PRESET 0 IS AVAILABLE AT THIS POINT IN TIME
DEFINE_FUNCTION PRESET_LOAD()
{
	ENQUEUE(sQueue, "DEV_CMD_PRESET_LOAD, DEV_CMD_SEPERATOR, '0'")
}

DEFINE_FUNCTION CHAR[MAX_DATA_ITEM] GET_PROPERTY(CHAR sKey[])
{
	SWITCH(sKey)
	{
		CASE MOD_KEY_IP_ADDRESS:
		{
			RETURN "MOD_KEY_IP_ADDRESS, MOD_SEPERATOR, sAddress"
		}
		CASE MOD_KEY_IP_PORT:
		{
			RETURN "MOD_KEY_IP_PORT, MOD_SEPERATOR, ITOA(nPort)"
		}
		DEFAULT:
		{
			RETURN 'INVALID PROPERTY KEY'
		}
	}
}

DEFINE_FUNCTION SET_PROPERTY(CHAR sKey[], CHAR sValue[])
{
	SWITCH(sKey)
	{
		CASE MOD_KEY_IP_ADDRESS:
		{
			IF(LENGTH_STRING(sValue) <= MAX_IP_ADDRESS)
				sAddress = sValue
		}
		CASE MOD_KEY_IP_PORT:
		{
			nPort = ATOI(sValue)
		}
	}
}

DEFINE_FUNCTION PASSTHRU(CHAR sCmd[])
{
	ENQUEUE(sQueue, sCmd)
}

DEFINE_FUNCTION REINIT()
{
	OFF[bInitializing]
	OFF[dvdDevice, DEVICE_COMMUNICATING]
	OFF[dvdDevice, DATA_INITIALIZED]
	
	RESET_ALL_STATES()
	
	OFF[nFailedResponseCount]
	
	sQueue = ""
	OFF[bQueueLocked]
	CLEAR_BUFFER sBuffer
	OFF[bLastOutWasHeartbeat]
	
	KILL_HEARTBEAT_TIMER()
	KILL_RESPONSE_TIMER()
	
	WAIT 20
	{
		IP_BOUND_CLIENT_OPEN(dvDevice.PORT, nLocalPort, sAddress, nPort, IP_UDP_2WAY)
		START_ASYNC()
		
		WAIT 20
		{
			DO_HEARTBEAT()
		}
	}
}

/////////////////////////////////////////////////////////////
// RESPONSE PROCESSING
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION PROCESS_STATE_RESPONSE(INTEGER nPort, INTEGER nType, INTEGER nState)
{
	IF(nState == STATE_OFF || nState == STATE_ON)
	{
		SWITCH(nType)
		{
			CASE CHAN_LED_RED:
			{
				SELECT
				{
					ACTIVE(nPort > 0 && nPort <= MAX_CHANNELS):
					{
						nRedLedState[nPort] = nState
						[dvdDevices[nPort], CHAN_LED_RED] = nState
						[vdvDevices[nPort], CHAN_LED_RED] = nState
					}
					ACTIVE(nPort == 0):
					{
						STACK_VAR INTEGER nLoop
						
						FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
						{
							nRedLedState[nLoop] = nState
							[dvdDevices[nLoop], CHAN_LED_RED] = nState
							[vdvDevices[nLoop], CHAN_LED_RED] = nState
						}
					}
				}
			}
			CASE CHAN_LED_GREEN:
			{
				SELECT
				{
					ACTIVE(nPort > 0 && nPort <= MAX_CHANNELS):
					{
						nGreenLedState[nPort] = nState
						[dvdDevices[nPort], CHAN_LED_GREEN] = nState
						[vdvDevices[nPort], CHAN_LED_GREEN] = nState
					}
					ACTIVE(nPort == 0):
					{
						STACK_VAR INTEGER nLoop
						
						FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
						{
							nGreenLedState[nLoop] = nState
							[dvdDevices[nLoop], CHAN_LED_GREEN] = nState
							[vdvDevices[nLoop], CHAN_LED_GREEN] = nState
						}
					}
				}
			}
			CASE CHAN_PHANTOM:
			{
				SELECT
				{
					ACTIVE(nPort > 0 && nPort <= MAX_CHANNELS):
					{
						nPhantomState[nPort] = nState
						[dvdDevices[nPort], CHAN_PHANTOM] = nState
						[vdvDevices[nPort], CHAN_PHANTOM] = nState
					}
					ACTIVE(nPort == 0):
					{
						STACK_VAR INTEGER nLoop
						
						FOR(nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
						{
							nPhantomState[nLoop] = nState
							[dvdDevices[nLoop], CHAN_PHANTOM] = nState
							[vdvDevices[nLoop], CHAN_PHANTOM] = nState
						}
					}
				}
			}
			CASE CHAN_ARM_C:
			{
				IF(nPort == 1)
				{
					nArmCState = nState
					[dvdDevices[nPort], CHAN_ARM_C] = nState
					[vdvDevices[nPort], CHAN_ARM_C] = nState
				}
			}
		}
	}
}

DEFINE_FUNCTION PROCESS_STATE_RESPONSE_INPUT(INTEGER nPort, INTEGER nState)
{
	IF((nPort > 0 && nPort <= MAX_CHANNELS) && (nState == STATE_OFF || nState == STATE_ON))
	{
		nInputState[nPort] = nState
		
		SELECT
		{
			ACTIVE(nState == STATE_OFF):
			{
				DO_RELEASE(dvdDevices[nPort], BTN_INPUT_EVENT)
				DO_RELEASE(vdvDevices[nPort], BTN_INPUT_EVENT)
			}
			ACTIVE(nState == STATE_ON):
			{
				DO_PUSH_TIMED(dvdDevices[nPort], BTN_INPUT_EVENT, DO_PUSH_TIMED_INFINITE)
				DO_PUSH_TIMED(vdvDevices[nPort], BTN_INPUT_EVENT, DO_PUSH_TIMED_INFINITE)
			}
		}
	}
}

/////////////////////////////////////////////////////////////
// HEARTBEAT
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION DO_HEARTBEAT()
{
	STACK_VAR CHAR sMsg[MAX_DATA_TOTAL]
	
	sMsg = DEV_CMD_VERSION
	
	ENQUEUE(sQueue, sMsg)
}

DEFINE_FUNCTION START_HEARTBEAT_TIMER()
{
	IF(!TIMELINE_ACTIVE(TL_HEARTBEAT))
	{
		TIMELINE_CREATE(TL_HEARTBEAT, lTlHeartbeat, 1, TIMELINE_ABSOLUTE, TIMELINE_ONCE)
	}
}

DEFINE_FUNCTION KILL_HEARTBEAT_TIMER()
{
	IF(TIMELINE_ACTIVE(TL_HEARTBEAT))
	{
		TIMELINE_KILL(TL_HEARTBEAT)
	}
}

/////////////////////////////////////////////////////////////
// RESPONSE TRACKING
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION START_RESPONSE_TIMER()
{
	IF(!TIMELINE_ACTIVE(TL_RESPONSE))
	{
		TIMELINE_CREATE(TL_RESPONSE, lTlResponse, 1, TIMELINE_ABSOLUTE, TIMELINE_ONCE)
	}
}

DEFINE_FUNCTION KILL_RESPONSE_TIMER()
{
	IF(TIMELINE_ACTIVE(TL_RESPONSE))
	{
		TIMELINE_KILL(TL_RESPONSE)
	}
}
	
DEFINE_FUNCTION GOOD_RESPONSE()
{
	ON[dvdDevice, DEVICE_COMMUNICATING]
	
	OFF[nFailedResponseCount]
	
	KILL_RESPONSE_TIMER()
	
	IF(bLastOutWasHeartbeat && !bInitializing)
	{
		GET_INITIALIZED()
	}
	
	OFF[bLastOutWasHeartbeat]
	OFF[bQueueLocked]
	
	DEQUEUE()
}

DEFINE_FUNCTION FAILED_RESPONSE()
{
	nFailedResponseCount++
	
	IF(nFailedResponseCount == MAX_FAILED_RSP)
	{
		REINIT()
	}
	ELSE
	{
		KILL_RESPONSE_TIMER()
		
		OFF[bLastOutWasHeartbeat]
		OFF[bQueueLocked]
		
		DEQUEUE()
		
		IF(QUEUE_HAS_ITEMS() == FALSE)
		{
			WAIT 20
			{
				DO_HEARTBEAT()
			}
		}
	}
}

/////////////////////////////////////////////////////////////
// INITIALIZATION
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION GET_INITIALIZED()
{
	IF(bInitializing == FALSE && IS_INITIALIZED() == FALSE)
	{
		ON[bInitializing]
		
		INIT_ALL_STATES()
	}
}

DEFINE_FUNCTION CHAR IS_INITIALIZED()
{
	STACK_VAR INTEGER nLoop
	
	FOR (nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
	{
		IF(nRedLedState[nLoop] == 65535 || nGreenLedState[nLoop] == 65535 || nInputState[nLoop] == 65535 || nPhantomState[nLoop] == 65535 || nArmCState == 65535)
		{
			RETURN FALSE
		}
	}
	
	RETURN TRUE
}

DEFINE_FUNCTION RESET_ALL_STATES()
{
	STACK_VAR INTEGER nLoop
	
	FOR (nLoop = 1; nLoop <= MAX_CHANNELS; nLoop++)
	{
		nRedLedState[nLoop] = 65535
		nGreenLedState[nLoop] = 65535
		nInputState[nLoop] = 65535
		nPhantomState[nLoop] = 65535
		nArmCState = 65535
		
		OFF[dvdDevices[nLoop], CHAN_LED_RED]
		OFF[vdvDevices[nLoop], CHAN_LED_RED]
		
		OFF[dvdDevices[nLoop], CHAN_LED_GREEN]
		OFF[vdvDevices[nLoop], CHAN_LED_GREEN]
		
		OFF[dvdDevices[nLoop], CHAN_PHANTOM]
		OFF[vdvDevices[nLoop], CHAN_PHANTOM]
		
		OFF[dvdDevices[1], CHAN_ARM_C]
		OFF[vdvDevices[1], CHAN_ARM_C]
		
		SEND_COMMAND dvdDevice,"MOD_KEY_SW_ADDRESS, MOD_SEPERATOR, ''"
		SEND_COMMAND dvdDevice,"MOD_KEY_IP_ADDRESS, MOD_SEPERATOR, ''"
	}	
}

DEFINE_FUNCTION INIT_ALL_STATES()
{
	ENQUEUE(sQueue, "DEV_CMD_GET_CH32, ' 0'")
	ENQUEUE(sQueue, "DEV_CMD_QUERY")
	ENQUEUE(sQueue, "DEV_CMD_GET_ARM_C")
	ENQUEUE(sQueue, "DEV_CMD_ADDRESS")
}

/////////////////////////////////////////////////////////////
// DEBUGGING MESSAGES
/////////////////////////////////////////////////////////////

DEFINE_FUNCTION DEBUG(INTEGER nState, CHAR sMsg[])
{
	IF(nState <= nDebugState)
	{
		SEND_STRING 0, "'DEBUG: ', sMsg"
	}
}

DEFINE_FUNCTION CHAR[1000] DEBUG_PRINT_HEX(CHAR sString[])
{
  STACK_VAR CHAR sTempString1[1000]
	STACK_VAR CHAR sTempString2[1000]
  STACK_VAR INTEGER nTemp

  IF (LENGTH_STRING(sString))
  {  
    sTempString2 = sString
    sTempString1 = '['
    
    WHILE (LENGTH_STRING(sTempString2))
    {
      nTemp = GET_BUFFER_CHAR(sTempString2)
      
      sTempString1 = "sTempString1, '$', RIGHT_STRING("'0', ITOHEX(nTemp)", 2), ','"
    }
    
    SET_LENGTH_STRING(sTempString1, LENGTH_STRING(sTempString1) - 1)
    
    sTempString1 = "sTempString1,']'"
  }
  
  RETURN sTempString1
}

(***********************************************************)
(*                STARTUP CODE GOES BELOW                  *)
(***********************************************************)
DEFINE_START

/////////////////////////////////////////////////////////////
// PORT SETUP
/////////////////////////////////////////////////////////////

SETUP_VIRTUAL_DEVICE_PORTS(vdvDevices, dvdDevices)

/////////////////////////////////////////////////////////////
// BUFFER SETUP
/////////////////////////////////////////////////////////////

CREATE_BUFFER dvDevice, sBuffer

/////////////////////////////////////////////////////////////
// LOCAL PORT SETUP
/////////////////////////////////////////////////////////////

nLocalPort = UDP_LOCAL_PORT_BASE + dvDevice.PORT
GET_IP_ADDRESS(dvMaster, uLocalIPAdress)

/////////////////////////////////////////////////////////////
// INITIALIZATION
/////////////////////////////////////////////////////////////

IF(sAddress && nPort)
{
	REINIT()
}

(***********************************************************)
(*                THE EVENTS GO BELOW                      *)
(***********************************************************)
DEFINE_EVENT

/////////////////////////////////////////////////////////////
// FROM DEVICE
/////////////////////////////////////////////////////////////

DATA_EVENT[dvDevice]
{
	STRING:
	{
		STACK_VAR CHAR sTemp[MAX_DATA_TOTAL]
		STACK_VAR CHAR sValue[MAX_DATA_ITEM]
		
		DEBUG(DEBUG_INFO, "'STRING FROM DEVICE: ', DATA.TEXT")
		
		WHILE(FIND_STRING(sBuffer, DEV_RSP_DELIM, 1))
		{
			sTemp = REMOVE_STRING(sBuffer, DEV_RSP_DELIM, 1)	
			SET_LENGTH_STRING(sTemp, LENGTH_STRING(sTemp) - LENGTH_STRING(DEV_RSP_DELIM))
			
			IF(!FIND_STRING(sTemp, DEV_RSP_NACK, 1) && FIND_STRING(sTemp, DEV_RSP_ACK, 1))
			{
				STACK_VAR INTEGER nStart
				STACK_VAR INTEGER nEnd
				STACK_VAR CHAR sPort[MAX_DATA_ITEM]
				STACK_VAR INTEGER nPort
				STACK_VAR INTEGER nRed
				STACK_VAR INTEGER nGreen
				STACK_VAR INTEGER nInput
				STACK_VAR CHAR sGarbage[MAX_DATA_ITEM]
				
				SELECT
				{
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_SET_CH32, 1)):
					{
						REMOVE_STRING(sTemp, "DEV_CMD_SET_CH32,' '", 1)
						
						sPort = LEFT_STRING(sTemp, 1)
						nPort = ATOI(sPort)
						REMOVE_STRING(sTemp, sPort, 1)
						
						nRed = FIND_STRING(sTemp, DEV_CMD_LED_RED, 1)
						nGreen = FIND_STRING(sTemp, DEV_CMD_LED_GREEN, 1)
						
						SELECT
						{
							ACTIVE(nRed > 0):
							{
								PROCESS_STATE_RESPONSE(nPort, CHAN_LED_RED, ATOI(sTemp))
							}
							ACTIVE(nGreen > 0):
							{
								PROCESS_STATE_RESPONSE(nPort, CHAN_LED_GREEN, ATOI(sTemp))
							}
						}
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_GET_CH32, 1)):
					{
						nStart = FIND_STRING(sTemp, ' CH', 1)
						sGarbage = LEFT_STRING(sTemp, nStart - 1)
						REMOVE_STRING(sTemp, sGarbage, 1)
						
						WHILE(FIND_STRING(sTemp, '=', 1))
						{
							nEnd = FIND_STRING(sTemp, '=', 1) + 2
							sValue = LEFT_STRING(sTemp, nEnd)
							REMOVE_STRING(sTemp, sValue, 1)
							
							nRed = FIND_STRING(sValue, DEV_CMD_LED_RED, 1)
							nGreen = FIND_STRING(sValue, DEV_CMD_LED_GREEN, 1)
							nInput = FIND_STRING(sValue, DEV_CMD_INPUT, 1)
							
							sPort = LEFT_STRING(sValue, (nRed + nGreen + nInput) - 1)
							nPort = ATOI(sPort)
							REMOVE_STRING(sValue, sPort, 1)
							
							SELECT
							{
								ACTIVE(nRed > 0):
								{
									PROCESS_STATE_RESPONSE(nPort, CHAN_LED_RED, ATOI(sValue))
								}
								ACTIVE(nGreen > 0):
								{
									PROCESS_STATE_RESPONSE(nPort, CHAN_LED_GREEN, ATOI(sValue))
								}
								ACTIVE(nInput > 0):
								{
									PROCESS_STATE_RESPONSE_INPUT(nPort, ATOI(sValue))
								}
							}
						}
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_QUERY, 1)):
					{
						nStart = FIND_STRING(sTemp, DEV_CMD_SET_PHANTOM, 1)
						sGarbage = LEFT_STRING(sTemp, nStart - 1)
						REMOVE_STRING(sTemp, sGarbage, 1)
						
						WHILE(FIND_STRING(sTemp, DEV_CMD_SET_PHANTOM, 1))
						{
							REMOVE_STRING(sTemp, DEV_CMD_SET_PHANTOM, 1)
							
							nEnd = FIND_STRING(sTemp, DEV_CMD_SET_PHANTOM, 1)
							sValue = LEFT_STRING(sTemp, nEnd - 1)
							
							nPort = ATOI(sValue)
							
							IF(FIND_STRING(sValue, 'ON', 1))
							{
								PROCESS_STATE_RESPONSE(nPort, CHAN_PHANTOM, STATE_ON)
							}
							ELSE
							{
								PROCESS_STATE_RESPONSE(nPort, CHAN_PHANTOM, STATE_OFF)
							}
						}
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_SET_PHANTOM, 1)):
					{
						REMOVE_STRING(sTemp, "DEV_CMD_SET_PHANTOM,' '", 1)
						
						sPort = LEFT_STRING(sTemp, 1)
						nPort = ATOI(sPort)
						REMOVE_STRING(sTemp, sPort, 1)
						
						PROCESS_STATE_RESPONSE(nPort, CHAN_PHANTOM, ATOI(sTemp))
					}
					
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_SET_ARM_C, 1)):
					{
						REMOVE_STRING(sTemp, "DEV_CMD_SET_ARM_C", 1)
						
						PROCESS_STATE_RESPONSE(1, CHAN_ARM_C, ATOI(sTemp))
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_GET_ARM_C, 1)):
					{
						REMOVE_STRING(sTemp, "DEV_CMD_GET_ARM_C", 1)
						
						PROCESS_STATE_RESPONSE(1, CHAN_ARM_C, ATOI(sTemp))
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_ADDRESS, 1)):
					{
						REMOVE_STRING(sTemp, DEV_CMD_ADDRESS, 1)
						
						sSwitchAddress = sTemp
						
						SEND_COMMAND dvdDevice,"MOD_KEY_SW_ADDRESS, MOD_SEPERATOR, sSwitchAddress"
						SEND_COMMAND dvdDevice,"MOD_KEY_IP_ADDRESS, MOD_SEPERATOR, sAddress"
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_PRESET_SAVE, 1)):
					{
						REMOVE_STRING(sTemp, "DEV_CMD_SET_ARM_C", 1)
						SEND_COMMAND dvdDevice,"MOD_KEY_PRESET_SAVED, MOD_SEPERATOR, ITOA(ATOI(sTemp))"
					}
					ACTIVE(FIND_STRING(sTemp, DEV_CMD_PRESET_LOAD, 1)):
					{
						ENQUEUE(sQueue, "DEV_CMD_QUERY")
					}
				}
			}
			
			IF(FIND_STRING(sTemp, DEV_CMD_INPUT_STATUS, 1))
			{
				STACK_VAR INTEGER nEnd
				STACK_VAR CHAR sPort[MAX_DATA_ITEM]
				STACK_VAR INTEGER nPort
				STACK_VAR INTEGER nRed
				
				REMOVE_STRING(sTemp, "DEV_CMD_INPUT_STATUS,' '", 1)
				
				nEnd = FIND_STRING(sTemp, '=', 1)
				sPort = LEFT_STRING(sTemp, nEnd - 1)
				nPort = ATOI(sPort)
				
				REMOVE_STRING(sTemp, sPort, 1)
				
				PROCESS_STATE_RESPONSE_INPUT(nPort, ATOI(sTemp))
			}
			
			GOOD_RESPONSE()
			
			IF(bInitializing && IS_INITIALIZED())
			{
				OFF[bInitializing]
				ON[dvdDevice, DATA_INITIALIZED]
			}
		}
	}
}

/////////////////////////////////////////////////////////////
// FROM PROGRAM
/////////////////////////////////////////////////////////////

DATA_EVENT[dvdDevices]
{
	COMMAND:
	{
		STACK_VAR CHAR sTemp[MAX_DATA_TOTAL]
		STACK_VAR CHAR sType[MAX_DATA_ITEM]
		STACK_VAR CHAR sKey[MAX_DATA_ITEM]
		STACK_VAR CHAR sValue[MAX_DATA_ITEM]
		
		DEBUG(DEBUG_INFO, "'COMMAND FROM PROGRAM: ', DATA.TEXT")
		
		sTemp  = DATA.TEXT
		sType  = PARSE_CMD_HEADER(sTemp)
		
		IF(DATA.DEVICE.PORT == 1)
		{
			SWITCH(sType)
			{
				CASE MOD_SET_PROPERTY:
				{
					sKey = PARSE_CMD_KEY(sTemp)
					sValue = sTemp
					SET_PROPERTY(sKey, sValue)
				}
				CASE MOD_PASSTHRU:
				{
					PASSTHRU(sTemp)
				}
				CASE MOD_REINIT:
				{
					REINIT()
				}
				CASE MOD_DEBUG:
				{
					sValue = sTemp
					
					IF(ATOI(sValue) > 0 && ATOI(sValue) <= 4)
					{
						nDebugState = ATOI(sValue)
					}
				}
			}
		}
	}
}

CHANNEL_EVENT[dvdDevices, CHAN_LED_RED]
CHANNEL_EVENT[dvdDevices, CHAN_LED_GREEN]
CHANNEL_EVENT[dvdDevices, CHAN_ARM_C]
CHANNEL_EVENT[dvdDevices, CHAN_PHANTOM]
CHANNEL_EVENT[dvdDevices, CHAN_PRESET_SAVE]
CHANNEL_EVENT[dvdDevices, CHAN_PRESET_LOAD]
{
	ON:
	{
		SWITCH(CHANNEL.CHANNEL)
		{
			CASE CHAN_LED_RED:
			{
				IF(nRedLedState[CHANNEL.DEVICE.PORT] == FALSE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_ON)
				}
			}
			CASE CHAN_LED_GREEN:
			{
				IF(nGreenLedState[CHANNEL.DEVICE.PORT] == FALSE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_ON)
				}
			}
			CASE CHAN_ARM_C:
			{
				IF(nArmCState == FALSE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_ON)
				}
			}
			CASE CHAN_PHANTOM:
			{
				IF(nPhantomState[CHANNEL.DEVICE.PORT] == FALSE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_ON)
				}
			}
			CASE CHAN_PRESET_SAVE:
			{
				PRESET_SAVE();
			}
			CASE CHAN_PRESET_LOAD:
			{
				PRESET_LOAD();
			}
		}
	}
	OFF:
	{
		SWITCH(CHANNEL.CHANNEL)
		{
			CASE CHAN_LED_RED:
			{
				IF(nRedLedState[CHANNEL.DEVICE.PORT] == TRUE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_OFF)
				}
			}
			CASE CHAN_LED_GREEN:
			{
				IF(nGreenLedState[CHANNEL.DEVICE.PORT] == TRUE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_OFF)
				}
			}
			CASE CHAN_ARM_C:
			{
				IF(nArmCState == TRUE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_OFF)
				}
			}
			CASE CHAN_PHANTOM:
			{
				IF(nPhantomState[CHANNEL.DEVICE.PORT] == TRUE)
				{
					UPDATE_STATE(CHANNEL.DEVICE.PORT, CHANNEL.CHANNEL, STATE_OFF)
				}
			}
		}
	}
}

/////////////////////////////////////////////////////////////
// TIMELINES
/////////////////////////////////////////////////////////////

TIMELINE_EVENT[TL_HEARTBEAT]
{
	DO_HEARTBEAT()
}

TIMELINE_EVENT[TL_RESPONSE]
{
	FAILED_RESPONSE()
}

(***********************************************************)
(*            THE ACTUAL PROGRAM GOES BELOW                *)
(***********************************************************)
DEFINE_PROGRAM

(***********************************************************)
(*                     END OF PROGRAM                      *)
(*        DO NOT PUT ANY CODE BELOW THIS COMMENT           *)
(***********************************************************)