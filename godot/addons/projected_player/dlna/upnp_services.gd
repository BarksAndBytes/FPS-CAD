extends RefCounted

## The UPnP MediaRenderer:1 description: the device document and the three services' SCPDs
## (the lists of actions and state variables a phone reads before it sends commands).

const DEVICE_TYPE := "urn:schemas-upnp-org:device:MediaRenderer:1"

## Short name → [service type, service id].
const SERVICES := {
	"AVTransport": ["urn:schemas-upnp-org:service:AVTransport:1", "urn:upnp-org:serviceId:AVTransport"],
	"RenderingControl": ["urn:schemas-upnp-org:service:RenderingControl:1", "urn:upnp-org:serviceId:RenderingControl"],
	"ConnectionManager": ["urn:schemas-upnp-org:service:ConnectionManager:1", "urn:upnp-org:serviceId:ConnectionManager"],
}

## What the renderer accepts: video it can convert with FFmpeg. "*" for the DLNA flags.
const SINK_TYPES := [
	"video/mp4", "video/x-m4v", "video/quicktime", "video/x-matroska", "video/webm", "video/ogg",
	"video/x-msvideo", "video/avi", "video/mpeg", "video/mp2t", "video/x-flv", "video/3gpp",
	"video/x-ms-wmv", "application/vnd.apple.mpegurl", "application/x-mpegURL", "application/ogg",
]

## Actions: name → [[argument, "in" or "out", related state variable], ...].
const ACTIONS := {
	"AVTransport": {
		"SetAVTransportURI": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["CurrentURI", "in", "AVTransportURI"], ["CurrentURIMetaData", "in", "AVTransportURIMetaData"]],
		"GetMediaInfo": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["NrTracks", "out", "NumberOfTracks"], ["MediaDuration", "out", "CurrentMediaDuration"],
			["CurrentURI", "out", "AVTransportURI"], ["CurrentURIMetaData", "out", "AVTransportURIMetaData"], ["NextURI", "out", "NextAVTransportURI"],
			["NextURIMetaData", "out", "NextAVTransportURIMetaData"], ["PlayMedium", "out", "PlaybackStorageMedium"], ["RecordMedium", "out", "RecordStorageMedium"],
			["WriteStatus", "out", "RecordMediumWriteStatus"]],
		"GetTransportInfo": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["CurrentTransportState", "out", "TransportState"],
			["CurrentTransportStatus", "out", "TransportStatus"], ["CurrentSpeed", "out", "TransportPlaySpeed"]],
		"GetPositionInfo": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Track", "out", "CurrentTrack"], ["TrackDuration", "out", "CurrentTrackDuration"],
			["TrackMetaData", "out", "CurrentTrackMetaData"], ["TrackURI", "out", "CurrentTrackURI"], ["RelTime", "out", "RelativeTimePosition"],
			["AbsTime", "out", "AbsoluteTimePosition"], ["RelCount", "out", "RelativeCounterPosition"], ["AbsCount", "out", "AbsoluteCounterPosition"]],
		"GetDeviceCapabilities": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["PlayMedia", "out", "PossiblePlaybackStorageMedia"],
			["RecMedia", "out", "PossibleRecordStorageMedia"], ["RecQualityModes", "out", "PossibleRecordQualityModes"]],
		"GetTransportSettings": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["PlayMode", "out", "CurrentPlayMode"], ["RecQualityMode", "out", "CurrentRecordQualityMode"]],
		"GetCurrentTransportActions": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Actions", "out", "CurrentTransportActions"]],
		"Stop": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"]],
		"Play": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Speed", "in", "TransportPlaySpeed"]],
		"Pause": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"]],
		"Seek": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Unit", "in", "A_ARG_TYPE_SeekMode"], ["Target", "in", "A_ARG_TYPE_SeekTarget"]],
		"Next": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"]],
		"Previous": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"]],
	},
	"RenderingControl": {
		"ListPresets": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["CurrentPresetNameList", "out", "PresetNameList"]],
		"SelectPreset": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["PresetName", "in", "A_ARG_TYPE_PresetName"]],
		"GetMute": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Channel", "in", "A_ARG_TYPE_Channel"], ["CurrentMute", "out", "Mute"]],
		"SetMute": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Channel", "in", "A_ARG_TYPE_Channel"], ["DesiredMute", "in", "Mute"]],
		"GetVolume": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Channel", "in", "A_ARG_TYPE_Channel"], ["CurrentVolume", "out", "Volume"]],
		"SetVolume": [["InstanceID", "in", "A_ARG_TYPE_InstanceID"], ["Channel", "in", "A_ARG_TYPE_Channel"], ["DesiredVolume", "in", "Volume"]],
	},
	"ConnectionManager": {
		"GetProtocolInfo": [["Source", "out", "SourceProtocolInfo"], ["Sink", "out", "SinkProtocolInfo"]],
		"GetCurrentConnectionIDs": [["ConnectionIDs", "out", "CurrentConnectionIDs"]],
		"GetCurrentConnectionInfo": [["ConnectionID", "in", "A_ARG_TYPE_ConnectionID"], ["RcsID", "out", "A_ARG_TYPE_RcsID"],
			["AVTransportID", "out", "A_ARG_TYPE_AVTransportID"], ["ProtocolInfo", "out", "A_ARG_TYPE_ProtocolInfo"],
			["PeerConnectionManager", "out", "A_ARG_TYPE_ConnectionManager"], ["PeerConnectionID", "out", "A_ARG_TYPE_ConnectionID"],
			["Direction", "out", "A_ARG_TYPE_Direction"], ["Status", "out", "A_ARG_TYPE_ConnectionStatus"]],
	},
}

## State variables: name → [data type, evented, allowed values or [min, max, step] for numbers].
const VARIABLES := {
	"AVTransport": {
		"TransportState": ["string", false, ["STOPPED", "PLAYING", "TRANSITIONING", "PAUSED_PLAYBACK", "NO_MEDIA_PRESENT"]],
		"TransportStatus": ["string", false, ["OK", "ERROR_OCCURRED"]],
		"PlaybackStorageMedium": ["string", false, ["NONE", "NETWORK"]],
		"RecordStorageMedium": ["string", false, ["NOT_IMPLEMENTED"]],
		"PossiblePlaybackStorageMedia": ["string", false, []],
		"PossibleRecordStorageMedia": ["string", false, []],
		"CurrentPlayMode": ["string", false, ["NORMAL"]],
		"TransportPlaySpeed": ["string", false, ["1"]],
		"RecordMediumWriteStatus": ["string", false, ["NOT_IMPLEMENTED"]],
		"CurrentRecordQualityMode": ["string", false, ["NOT_IMPLEMENTED"]],
		"PossibleRecordQualityModes": ["string", false, []],
		"NumberOfTracks": ["ui4", false, [0, 1, 1]],
		"CurrentTrack": ["ui4", false, [0, 1, 1]],
		"CurrentTrackDuration": ["string", false, []],
		"CurrentMediaDuration": ["string", false, []],
		"CurrentTrackMetaData": ["string", false, []],
		"CurrentTrackURI": ["string", false, []],
		"AVTransportURI": ["string", false, []],
		"AVTransportURIMetaData": ["string", false, []],
		"NextAVTransportURI": ["string", false, []],
		"NextAVTransportURIMetaData": ["string", false, []],
		"RelativeTimePosition": ["string", false, []],
		"AbsoluteTimePosition": ["string", false, []],
		"RelativeCounterPosition": ["i4", false, []],
		"AbsoluteCounterPosition": ["i4", false, []],
		"CurrentTransportActions": ["string", false, []],
		"LastChange": ["string", true, []],
		"A_ARG_TYPE_SeekMode": ["string", false, ["REL_TIME", "ABS_TIME"]],
		"A_ARG_TYPE_SeekTarget": ["string", false, []],
		"A_ARG_TYPE_InstanceID": ["ui4", false, []],
	},
	"RenderingControl": {
		"PresetNameList": ["string", false, []],
		"LastChange": ["string", true, []],
		"Mute": ["boolean", false, []],
		"Volume": ["ui2", false, [0, 100, 1]],
		"A_ARG_TYPE_Channel": ["string", false, ["Master"]],
		"A_ARG_TYPE_InstanceID": ["ui4", false, []],
		"A_ARG_TYPE_PresetName": ["string", false, ["FactoryDefaults"]],
	},
	"ConnectionManager": {
		"SourceProtocolInfo": ["string", true, []],
		"SinkProtocolInfo": ["string", true, []],
		"CurrentConnectionIDs": ["string", true, []],
		"A_ARG_TYPE_ConnectionStatus": ["string", false, ["OK", "ContentFormatMismatch", "InsufficientBandwidth", "UnreliableChannel", "Unknown"]],
		"A_ARG_TYPE_ConnectionManager": ["string", false, []],
		"A_ARG_TYPE_Direction": ["string", false, ["Input", "Output"]],
		"A_ARG_TYPE_ProtocolInfo": ["string", false, []],
		"A_ARG_TYPE_ConnectionID": ["i4", false, []],
		"A_ARG_TYPE_AVTransportID": ["i4", false, []],
		"A_ARG_TYPE_RcsID": ["i4", false, []],
	},
}


static func sink_protocol_info() -> String:
	var parts := PackedStringArray()
	for mime in SINK_TYPES:
		parts.append("http-get:*:%s:*" % mime)
	return ",".join(parts)


static func device_xml(friendly_name: String, udn: String) -> String:
	var services := ""
	for short in SERVICES:
		services += "<service><serviceType>%s</serviceType><serviceId>%s</serviceId><SCPDURL>/dlna/%s.xml</SCPDURL><controlURL>/dlna/%s/control</controlURL><eventSubURL>/dlna/%s/event</eventSubURL></service>" % [
			SERVICES[short][0], SERVICES[short][1], short, short, short]
	return ('<?xml version="1.0" encoding="utf-8"?>\n'
		+ '<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">'
		+ '<specVersion><major>1</major><minor>0</minor></specVersion><device>'
		+ '<deviceType>%s</deviceType>' % DEVICE_TYPE
		+ '<friendlyName>%s</friendlyName>' % friendly_name.xml_escape()
		+ '<manufacturer>ProjectedPlayer</manufacturer><manufacturerURL>https://github.com/BarksAndBytes/ProjectedPlayer</manufacturerURL>'
		+ '<modelDescription>Video screen in a Godot game</modelDescription><modelName>ProjectedPlayer</modelName><modelNumber>1</modelNumber>'
		+ '<UDN>%s</UDN>' % udn
		+ '<dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>'
		+ '<serviceList>%s</serviceList></device></root>' % services)


static func scpd_xml(short: String) -> String:
	var actions := ""
	for action in ACTIONS[short]:
		var args := ""
		for a in ACTIONS[short][action]:
			args += "<argument><name>%s</name><direction>%s</direction><relatedStateVariable>%s</relatedStateVariable></argument>" % a
		actions += "<action><name>%s</name><argumentList>%s</argumentList></action>" % [action, args] if args != "" else "<action><name>%s</name></action>" % action
	var vars := ""
	for v in VARIABLES[short]:
		var info: Array = VARIABLES[short][v]
		var extra := ""
		var allowed: Array = info[2]
		if not allowed.is_empty():
			if info[0] == "string":
				for value in allowed:
					extra += "<allowedValue>%s</allowedValue>" % value
				extra = "<allowedValueList>%s</allowedValueList>" % extra
			else:
				extra = "<allowedValueRange><minimum>%d</minimum><maximum>%d</maximum><step>%d</step></allowedValueRange>" % allowed
		vars += '<stateVariable sendEvents="%s"><name>%s</name><dataType>%s</dataType>%s</stateVariable>' % ["yes" if info[1] else "no", v, info[0], extra]
	return ('<?xml version="1.0" encoding="utf-8"?>\n'
		+ '<scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>'
		+ '<actionList>%s</actionList><serviceStateTable>%s</serviceStateTable></scpd>' % [actions, vars])
