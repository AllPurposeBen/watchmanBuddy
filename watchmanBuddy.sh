#!/bin/bash

###This script is called at boot to allow WM to help set munki manifest and for munki to record asset ID
version="1.0.0"

## Are we root yet?
if [ $(whoami) != "root" ]; then
	echo "Sudo make me a sandwich."
	exit 2
fi

#Sanity check, is WM installed?
if [ ! -e /Library/MonitoringClient/RunClient ]; then
	echo "WM not installed, bailing!"
	exit 2
fi

#global vars
apiKey="CHANGE-ME-!!!!!" #You WM API key
subD="your_watchman_subdomain" # you WM sub domain

##Functions
# AssetID 
checkAID () {
#set some local vars
local hardwareAID=$(nvram -p | grep ASSET | awk -F ' ' '{print $2}')
local wmAIDrecorded=$(defaults read /Library/MonitoringClient/ClientSettings Asset_ID 2/dev/null)
local WMID=$(defaults read /Library/MonitoringClient/ClientSettings WatchmanID)
#Now lets check
if [ -z "$WMID" ]; then
	#WM problem
	echo "No WM ID set, bailing out!"
	return 1
elif [ -z "$hardwareAID" ]; then
	#no hardware ID set. Could be a new, could have been reset by nvram wipe. Send server a blank so we know it's unset
	echo "No asset ID configured, sending a blank to the WM server."
	curl -s -X PUT https://"#subD".monitoringclient.com/v2.5/computers/"$WMID"?api_key="$apiKey" -d computer[asset_id]="" > /dev/null
	defaults write /Library/Preferences/com.apple.loginwindow LoginwindowText -string "Asset Tag: $hardwareAID" 
	return 5
else
	#check AID format of being 5 numbers
	case "$hardwareAID" in
		[0-9][0-9][0-9][0-9][0-9])
			#good format, check for hardware and software record to match
			if [ "$hardwareAID" == "$wmAIDrecorded" ]; then
				#yay, a match, nothing to see here
				echo "IDs match: $hardwareAID"
				returnStat=0
			else
				#mismatch, update WM server and recheck
				echo "Hardware and Software IDs mismatch, attempting to set software ID on WM server."
				local setAttempt=$(curl -s -X PUT https://"$subD".monitoringclient.com/v2.5/computers/"$WMID"?api_key="$apiKey" -d computer[asset_id]="$hardwareAID" | python -m json.tool | grep '"asset_id":' | xargs | awk -F ': ' '{print $2}' | tr -d '[:punct:]')
				if [ "$setAttempt" == "$hardwareAID" ]; then
					echo "AssetID successfully set on WM server"
					#now run WM so that locally we get what the server just got
					/Library/MonitoringClient/RunClient -F
					returnStat=0
				else
					echo "attempt to set AssetID on WM server failed!"
					returnStat=2
				fi
			fi
			#set the login window text for good measure anyway
			defaults write /Library/Preferences/com.apple.loginwindow LoginwindowText -string "Asset Tag: $hardwareAID" 
			return "$returnStat"
	  ;;
	 	*)
			#format is bad, send a bad marker to the server so we have something to see
			echo "Bad format on asset ID detected. Assigning BADASSETID to server value"
			curl -s -X PUT https://"$subD".monitoringclient.com/v2.5/computers/"$WMID"?api_key="$apiKey" -d computer[asset_id]="BADASSETID" > /dev/null
			return 3
	  ;;
	esac
fi
}

# Munki Manifest
setMunki () {
#First, check if an override (ARD field #4) is set, if it is, set it as the munki manifest and then bail.
local overrideManifest=$(defaults read /Library/Preferences/com.apple.RemoteDesktop \Text4 2>/dev/null)
local currentMunkiManifest=$(defaults read /Library/Preferences/ManagedInstalls ClientIdentifier 2>/dev/null)
if [ -n "$overrideManifest" ] && [ "$overrideManifest" != "setup" ] && [ "$overrideManifest" != "default" ]; then
	#it's set to something other than the default or setup key, set the munki manifest to it
	echo "Override manifest set, setting munki manifest to $overrideManifest"
	defaults write /Library/Preferences/ManagedInstalls ClientIdentifier "$overrideManifest"
	return 0
elif [ "$overrideManifest" == "default" ]; then
	echo "Default flag set, using default munki manifest set on server"
	#the default flag is set, set the manifest to blank so it uses the site default or a server side serial numbered manifest
	defaults write /Library/Preferences/ManagedInstalls ClientIdentifier ""
	return 0
else
	#we need to use WM group and munki manifest.
	#first, check and see if we already match and can bail?
	local WMclientGroup=$(defaults read /Library/MonitoringClient/ClientSettings.plist ClientGroup 2>/dev/null)
	local munkiManifest=$(defaults read /Library/Preferences/ManagedInstalls.plist ClientIdentifier)
	if [ "$WMclientGroup" == "$munkiManifest" ]; then
		#we're already matching, bail
		echo "WM group and munki manifest should match and they do. Nothing to see here...."
		return 0
	elif [ "$WMclientGroup" == "NEW" ] || [ -z "$WMclientGroup" ]; then
		#group doesn't really help us here, set munki manifest to be blank to use site default manifest
		echo "No helpful WM group set, using munki server default manifest"
		defaults write /Library/Preferences/ManagedInstalls ClientIdentifier ""
	else
		# we don't match but should, update WM so that we have current group info
		echo "Running WM manually to get most current info"
		/Library/MonitoringClient/RunClient -F
		local WMclientGroup=$(defaults read /Library/MonitoringClient/ClientSettings.plist ClientGroup 2>/dev/null)
		#set munki manifest to be WM group name
		echo "Setting munki manifest to $WMclientGroup"
		defaults write /Library/Preferences/ManagedInstalls ClientIdentifier "$WMclientGroup"
	fi
fi
}

### Take input args and do something

case "$1" in
	"--asset")
		checkAID
		;;
	"--manifest")
		setMunki
		;;
	"--version"|"-v")
		echo "$version"
		exit 0
		;;
	"--set-asset")
		nvram ASSET="$2"
		checkAID
		;;
	"--set-manifest")
		defaults write /Library/Preferences/com.apple.RemoteDesktop \Text4 "$2"
		setMunki
		;;
	*)
		echo "Available arguments are --asset for checking asset ID and --manifest for checking/auto-setting munki manifest."
		echo "You can also set values with --set-asset <asset#> or --set-manifest <name_of_manifest>."
		exit 1
		;;
esac
