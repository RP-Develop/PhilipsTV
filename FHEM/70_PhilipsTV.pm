# $Id: 70_PhilipsTV.pm 164124 2024-10-03 00:00:00Z RalfP $
###############################################################################
#
#     70_PhilipsTV.pm 
#
#     An FHEM Perl module for controlling of PhilipsTV Television
#
#	  https://github.com/RP-Develop/PhilipsTV
#
#	  Based on
#     - 70_PHTV  	https://wiki.fhem.de/wiki/PHTV  	(Loredo)
#	  - pylips.py  	https://github.com/eslavnov/pylips  (eslavnov@gmail.com)
#     - Upnp 	-> 78_MagentaTV         (ich selbst)
#     			-> SONOS 				(Reinerlein)
#	  			-> 98_DLNARenderer.pm 	(dominik)
#     
#     - PHILIPS TV (2015+) UNOFFICIAL API REFERENCE https://github.com/eslavnov/pylips/blob/master/docs/Home.md
#
#     Important to install additional: sudo cpan install LWP::Protocol::https
#
#     many thanks for this pre work 
#     and thanks to all Fhem developers 
#
#
################################################################################
#
# Loglevel
# 0		nur die wichtigsten Nachrichten (z.B. Server Start/Stop) werden ausgegeben
# 1		zusätzlich werden Fehlermeldungen und unbekannte Pakete ausgegeben
# 2		Meldungen über die wichtigsten Ereignisse oder Alarme
# 3		gesendete Befehle werden protokolliert
# 4		es wird protokolliert, was die einzelnen Geräte empfangen
# 5		umfangreiche Meldungen, vor allem auch zur Fehlereingrenzung (und damit hauptsächlich für die jeweiligen Modulentwickler bestimmt)
#
################################################################################
#
# ToDo
# Loglevels besser definieren
# HDMI anzeigen - wenn irgendwie möglich
#
################################################################################

package main;
use strict;
use warnings;

# Laden evtl. abhängiger Perl- bzw. FHEM-Hilfsmodule
use HttpUtils; 		# https://wiki.fhem.de/wiki/HttpUtils
use JSON;
use Digest::SHA qw(hmac_sha1_base64 hmac_sha1_hex);
use MIME::Base64;
use Blocking;
use HTML::Entities;
use Data::Dumper;
use LWP::UserAgent;
use LWP::Protocol::https;
use HTTP::Request;
use Encode qw(encode decode);
use experimental 'smartmatch';


# UPnP::ControlPoint laden
my $gPath = '';
BEGIN {
	$gPath = substr($0, 0, rindex($0, '/'));
}
if (lc(substr($0, -7)) eq 'fhem.pl') {
	$gPath = $attr{global}{modpath}.'/FHEM';
}
use lib ($gPath.'/lib', $gPath.'/FHEM/lib', './FHEM/lib', './lib', './FHEM', './', '/usr/local/FHEM/share/fhem/FHEM/lib');

use UPnP::ControlPoint;

# Modul Constanten #############################################################

use constant VERSION 			   	=> "v1.0.0";

use constant TERMINAL_VENDOR	   	=> "Fhem";
use constant USER_AGENT 		   	=> "Fhem";

use constant INITIALIZE        	   	=> 0;
use constant FIRSTFOUND	           	=> 1;
use constant FOUND		           	=> 2;
use constant REMOVED 		       	=> 3;

use constant PAIR_UNDEF	           	=> 0;
use constant PAIR_OK 	           	=> 1;
use constant PAIR_NECESSARY        	=> 2;
use constant PAIR_NOT_NECESSARY    	=> 3;

use constant PROTOCOL				=> "https://";
use constant PORT					=> 1926;
use constant API					=> 6;

# Transitions ##################################################################

my %upnpState = (
					"0" => "initializing",
					"1" => "firstfound",
					"2" => "found",
					"3" => "removed"
				);
				


# Definitions ##################################################################

my $client = LWP::UserAgent->new();
my $request = HTTP::Request->new(); 

$client->ssl_opts(SSL_fingerprint => 'sha1$96A52B034901D9580C9ECFD4B6C9442EC483C3EB'); #aus restfultv_tpvision_com.crt
$client->agent(USER_AGENT);


my %deviceData = (
                    "device" => {
                                "device_name"     => "heliotrope",
                                "device_os"       => "Android",
                                "app_name"        => TERMINAL_VENDOR,
                                "type"            => "native",
                                "app_id"          => "app.id",
                                "id"              => "",
                            },
                    "scope" => ["read", "write", "control"]
                );

my %notifychange = (					
					"notification" => {
										"context" 				=> {},
										"network/devices" 		=> [],
										"input/textentry" 		=> {},
										"input/pointer" 		=> {},
										"channeldb/tv" 			=> {},
										"activities/tv" 		=> {},
										"activities/current" 	=> {},
										"applications/version" 	=> "",
										"applications" 			=> {},
										"system/epgsource" 		=> {},
										"powerstate" 			=> {},
										"system/nettvversion" 	=> "",
										"system/storage/status" => "",
										"recordings/list" 		=> {},
										"companionlauncher" 	=> {}
										}
					);
					
my %commands 	= (
          	"get" 		=> {
                     		"channeldb" 						=> {"path" => "channeldb/tv"},
                     		"channelLists" 						=> {"path" => "channeldb/tv/channelLists/all"},
                     		"favoriteLists" 					=> {"path" => "channeldb/tv/favoriteLists/all"},	
                     		"currentChannel" 					=> {"path" => "activities/tv"},
                     		"currentApp" 						=> {"path" => "activities/current"},
                     		"applications"						=> {"path" => "applications"},
                     		"input" 							=> {"path" => "sources/current"},					# kommt nur 404, scheint nicht zu existieren
                     		"volume" 							=> {"path" => "audio/volume"},
                     		"powerstate" 						=> {"path" => "powerstate"},                      	#On, Standby, StandbyKeep
                     		"ambihue_status" 					=> {"path" => "HueLamp/power"},
                     		"network" 							=> {"path" => "network/devices"},
                     		"system"							=> {"path" => "system"},
                     		"menuitemsSettingsStructure" 		=> {"path" => "menuitems/settings/structure"}
                   		},
           	"post" 		=> {
							"notify"							=> {"path" => "notifychange","body" => {"notification" => {"powerstate" => {},"HueLamp/power" => {},"audio/volume" => {"muted" => "false","current" => 0},"system/storage/status" => '',"network/devices" => [],"channeldb/tv" => {},"activities/current" => {},"activities/tv" => {},}}}, # siehe %notifychange 
          		            "pair"                              => {"path" => "pair/request","body" => {}},            #,"body" => {"device" => {"device_name" => "heliotrope","device_os" => "Android","app_name" => "Fhem","type" => "native","app_id" => "app.id","id" => ""},"scope" => ["read", "write", "control"]}},
                            "grant"                             => {"path" => "pair/grant","body" => {}},              #,"body" => {}},
                            "powerstate_on" 		            => {"path" => "powerstate","body" => {"powerstate" => "On"}},
                            "powerstate_standby" 		        => {"path" => "powerstate","body" => {"powerstate" => "Standby"}},
          		            "volume_set"      	                => {"path" => "audio/volume","body" => {"muted" => "false","current" => 0}}, # "muted" => "false" muss evtl. als Bool übergeben werden im JSON
                      		"menuitemsSettingsCurrent" 			=> {"path" => "menuitems/settings/current","body" => {"nodes" => [{"nodeid" => 0000000000}]}},
                      		"menuitemsSettingsUpdate" 			=> {"path" => "menuitems/settings/update","body" => {"values" => [{"value" => {"Nodeid" => 0000000000,"data" => {"selected_item" => 0}}}]}},
                      		"setChannel" 						=> {"path" => "activities/tv","body" => {"channel" => {"ccid" => 0,"preset" => "","name" => ""},"channelList" => {"id" => "","version" => ""}}},
                            "standby"                           => {"path" => "input/key","body" => {"key" => "Standby"}},                     		
          		            "mute"                              => {"path" => "input/key","body" => {"key" => "Mute"}},
                            "volume_down"                       => {"path" => "input/key","body" => {"key" => "VolumeDown"}},
                            "volume_up"                         => {"path" => "input/key","body" => {"key" => "VolumeUp"}},
                      		"previous" 	                        => {"path" => "input/key","body" => {"key" => "Previous"}},
                      		"yellow" 	                        => {"path" => "input/key","body" => {"key" => "YellowColour"}},
                      		"red" 								=> {"path" => "input/key","body" => {"key" => "RedColour"}},
                            "green"                             => {"path" => "input/key","body" => {"key" => "GreenColour"}},
                            "blue"                              => {"path" => "input/key","body" => {"key" => "BlueColour"}},
                            "ambilight_onoff"                   => {"path" => "input/key","body" => {"key" => "AmbilightOnOff"}},
                            "digit_0"                           => {"path" => "input/key","body" => {"key" => "Digit0"}},
                            "digit_1"                           => {"path" => "input/key","body" => {"key" => "Digit1"}},
                            "digit_2"                           => {"path" => "input/key","body" => {"key" => "Digit2"}},
                            "digit_3"                           => {"path" => "input/key","body" => {"key" => "Digit3"}},
                      		"digit_4" 							=> {"path" => "input/key","body" => {"key" => "Digit4"}},
                            "digit_5"                           => {"path" => "input/key","body" => {"key" => "Digit5"}},
                            "digit_6"                           => {"path" => "input/key","body" => {"key" => "Digit6"}},
                            "digit_7"                           => {"path" => "input/key","body" => {"key" => "Digit7"}},
                            "digit_8"                           => {"path" => "input/key","body" => {"key" => "Digit8"}},
                            "digit_9"                           => {"path" => "input/key","body" => {"key" => "Digit9"}},
                            "dot"                               => {"path" => "input/key","body" => {"key" => "Dot"}},
                            "record"                            => {"path" => "input/key","body" => {"key" => "Record"}},
                            "channel_up"                        => {"path" => "input/key","body" => {"key" => "ChannelStepUp"}},
                            "stop"                              => {"path" => "input/key","body" => {"key" => "Stop"}},
                            "back"                              => {"path" => "input/key","body" => {"key" => "Back"}},
                            "pause"                             => {"path" => "input/key","body" => {"key" => "Pause"}},
                            "cursor_right"                      => {"path" => "input/key","body" => {"key" => "CursorRight"}},
                            "adjust"                            => {"path" => "input/key","body" => {"key" => "Adjust"}},
                            "confirm"                           => {"path" => "input/key","body" => {"key" => "Confirm"}},
                      		"cursor_up" 						=> {"path" => "input/key","body" => {"key" => "CursorUp"}},
                            "cursor_down"                       => {"path" => "input/key","body" => {"key" => "CursorDown"}},
                            "play_pause"                        => {"path" => "input/key","body" => {"key" => "PlayPause"}},
                            "online"                            => {"path" => "input/key","body" => {"key" => "Online"}},
                            "source"                            => {"path" => "input/key","body" => {"key" => "Source"}},
                            "channel_down"                      => {"path" => "input/key","body" => {"key" => "ChannelStepDown"}},
                            "info"                              => {"path" => "input/key","body" => {"key" => "Info"}},
                            "rewind"                            => {"path" => "input/key","body" => {"key" => "Rewind"}},
                            "play"                              => {"path" => "input/key","body" => {"key" => "Play"}},
                      		"watch_tv" 							=> {"path" => "input/key","body" => {"key" => "WatchTV"}},
                      		"cursor_left" 						=> {"path" => "input/key","body" => {"key" => "CursorLeft"}},
                      		"viewmode" 							=> {"path" => "input/key","body" => {"key" => "Viewmode"}},
                      		"teletext" 							=> {"path" => "input/key","body" => {"key" => "Teletext"}},
                      		"find" 								=> {"path" => "input/key","body" => {"key" => "Find"}},
                      		"options" 							=> {"path" => "input/key","body" => {"key" => "Options"}},
                      		"next" 								=> {"path" => "input/key","body" => {"key" => "Next"}},
                      		"fast_forward" 						=> {"path" => "input/key","body" => {"key" => "FastForward"}},
                      		"home" 								=> {"path" => "input/key","body" => {"key" => "Home"}},
                      		"subtitle" 							=> {"path" => "input/key","body" => {"key" => "Subtitle"}},
                            "ambihue_on"                        => {"path" => "HueLamp/power","body" => {"power" => "On"}},
                            "ambihue_off"                       => {"path" => "HueLamp/power","body" => {"power" => "Off"}},
                            "ambilight_on"                      => {"path" => "ambilight/power","body" => {"power" => "On"}},
                      		"ambilight_off" 					=> {"path" => "ambilight/power","body" => {"power" => "Off"}},
#                             "ambilight_brightness"              => {"path" => "menuitems/settings/update","body" => {"values" => [{"value" => {"data" => {},"string_id" => "Brightness","Available" => "true","Nodeid" => 2131230769,"Controllable" => "true"}}]}},
                            "ambilight_color"                   => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "true","colorSettings" => {"colorDelta" => {"saturation" => 0,"brightness" => 0,"hue" => 0},"color" => {},"speed" => 255},"styleName" => "FOLLOW_COLOR","algorithm" => "MANUAL_HUE"}},
                            "ambilight_audio_strobo"            => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "STROBO","styleName" => "FOLLOW_AUDIO"}},
                            "ambilight_audio_knight_rider_2"    => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "KNIGHT_RIDER_ALTERNATING","styleName" => "FOLLOW_AUDIO"}},
                            "ambilight_audio_spectrum"          => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "SPECTRUM_ANALYZER","styleName" => "FOLLOW_AUDIO"}},
                            "ambilight_color_fresh_nature"      => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "FRESH_NATURE","styleName" => "FOLLOW_COLOR","stringValue" => "Fresh Nature"}},
                            "ambilight_audio_party"             => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "PARTY","styleName" => "FOLLOW_AUDIO"}},
                            "ambilight_audio_knight_rider_1"    => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "KNIGHT_RIDER_CLOCKWISE","styleName" => "FOLLOW_AUDIO"}},
                            "ambilight_video_vivid"             => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "VIVID","styleName" => "FOLLOW_VIDEO"}},
                            "ambilight_video_game"              => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "GAME","styleName" => "FOLLOW_VIDEO"}},
                            "ambilight_color_cool_white"        => {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "PTA_LOUNGE","stringValue" => "Cool White","styleName" => "FOLLOW_COLOR"}},
                      		"ambilight_audio_adapt_colors" 		=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "ENERGY_ADAPTIVE_COLORS","styleName" => "FOLLOW_AUDIO"}},
                      		"ambilight_video_natural" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "NATURAL","styleName" => "FOLLOW_VIDEO"}},
                      		"ambilight_video_comfort" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "COMFORT","styleName" => "FOLLOW_VIDEO"}},
                      		"ambilight_audio_random" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "MODE_RANDOM","styleName" => "FOLLOW_AUDIO"}},
                      		"ambilight_video_relax" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "RELAX","styleName" => "FOLLOW_VIDEO"}},
                      		"ambilight_color_deep_water" 		=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "DEEP_WATER","styleName" => "FOLLOW_COLOR","stringValue" => "Deep Water"}},
                      		"ambilight_audio_adapt_brightness" 	=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "ENERGY_ADAPTIVE_BRIGHTNESS","styleName" => "FOLLOW_AUDIO"}},
                      		"ambilight_color_warm_white" 		=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "ISF","styleName" => "FOLLOW_COLOR","stringValue" => "Warm White"}},
                      		"ambilight_video_standard" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "STANDARD","styleName" => "FOLLOW_VIDEO"}},
                      		"ambilight_color_hot_lava" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "HOT_LAVA","stringValue" => "Hot Lava","styleName" => "FOLLOW_COLOR"}},
                      		"ambilight_audio_vu_meter" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "VU_METER","styleName" => "FOLLOW_AUDIO"}},
                    		"ambilight_audio_flash" 			=> {"path" => "ambilight/currentconfiguration","body" => {"isExpert" => "false","menuSetting" => "RANDOM_PIXEL_FLASH","styleName" => "FOLLOW_AUDIO"}},
                            "launchApplication"                        => {"path" => "activities/launch","body" => {"intent" => {"component" => {
                            																												"className" => "fi.mtvkatsomo.androidtv.MainActivity",
                            																												"packageName" => "fi.mtvkatsomo"}
                            																												},
                            																								"action" => "empty"}
                            																							}, 
                            "google_assistant"                  => {"path" => "activities/launch","body" => {"intent" => {
                                                                                                                            "component" => {
                                                                                                                                             "className" => "com.google.android.apps.tvsearch.app.launch.trampoline.SearchActivityTrampoline",
                                                                                                                                             "packageName" => "com.google.android.katniss"
                                                                                                                                           },
                                                                                                                            "action" => "Intent {  act=android.intent.action.ASSIST cmp=com.google.android.katniss/com.google.android.apps.tvsearch.app.launch.trampoline.SearchActivityTrampoline flg=0x10200000 }",
                                                                                                                            "extras" => {
                                                                                                                                          "query" => ""
                                                                                                                                        }
                                                                                                                          }
                                                                                                            }
                                                                                                },
#                             "input_hdmi_1"                      => {"body" => {"query" => "HDMI 1"}},
#                             "input_hdmi_2"                      => {"body" => {"query" => "HDMI 2"}},
#                             "input_hdmi_3"                      => {"body" => {"query" => "HDMI 3"}},
#                             "input_hdmi_4"                      => {"body" => {"query" => "HDMI 4"}},
                    }
        );

# FHEM Modulfunktionen #########################################################

sub PhilipsTV_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}      		= "PhilipsTV_Define";
    $hash->{UndefFn}    		= "PhilipsTV_Undef";
    $hash->{DeleteFn} 			= "PhilipsTV_Delete";
    $hash->{SetFn}      		= "PhilipsTV_Set";
    $hash->{GetFn}      		= "PhilipsTV_Get";
    $hash->{AttrFn}     		= "PhilipsTV_Attr";
    #$hash->{NotifyFn}           = "PhilipsTV_Notify";
    $hash->{ReadFn}     		= "PhilipsTV_Read";
    #$hash->{ShutdownFn} 		= "PhilipsTV_Shutdown";
    $hash->{DelayedShutdownFn} 	= "PhilipsTV_DelayedShutdown";

  	# Attr sind den Geräten über setDevAttrList zugeordnet 
  	$hash->{AttrList} =	"disable:1,0 expert:1,0 ";
  	$hash->{AttrList} .= $readingFnAttributes;
 	
}

sub PhilipsTV_Define {
    my ($hash, $def) = @_;
    
    my @param = split('[ \t]+', $def);
    
   	$hash->{NAME}  = $param[0];
	my $name = $hash->{NAME};
	
	$hash->{VERSION} = VERSION;
	
	Log3 $name, 5, $name.": <Define> called for $name : ".join(" ",@param);
    
	if(IsDisabled($name) || !defined($name)) {
	    RemoveInternalTimer($hash);
	    $hash->{STATE} = "Disabled";
	    return undef;
	}
	
   	if(($param[2] eq "TV") && (scalar(@param) == 4)){
		$hash->{SUBTYPE} = "TV";
        $hash->{IP} = $param[3];
		
		setDevAttrList($name, "disable:1,0 expert:1,0 deviceID authKey macAddress renewSubscription pollingInterval defaultChannelList defaultFavoriteList pingTimeout:1,2,3 requestTimeout:1,2,3,4,5 " .$readingFnAttributes); 

		readingsSingleUpdate($hash,"state","offline",1);
		readingsSingleUpdate($hash,"data","notready",1);
				
		PhilipsTV_StartTV($hash);

   	}
   	elsif((($param[2] eq "PHILIPS") && (scalar(@param) == 3)) || (scalar(@param) == 2)){
		$hash->{SUBTYPE} = "PHILIPS";

		$hash->{DEF} = "PHILIPS";
		
   	    setDevAttrList($name, "disable:1,0 expert:1,0 acceptedModelName ignoreUDNs acceptedUDNs ignoredIPs usedonlyIPs rescanNetworkInterval startUpnpSearchInterval subscriptionPort searchPort reusePort:0,1 " .$readingFnAttributes); 
   	    
   	    #wenn kein room angegeben ist - trifft bei neuem define zu 
   	    CommandAttr(undef, $name." room PhilipsTV") if ( AttrVal( $name, "room", "" ) eq "" );
   	    
   	    if( $init_done ) {
			InternalTimer(gettimeofday()+3, "PhilipsTV_StartPHILIPS", $hash);
		}
		else{
			InternalTimer(gettimeofday()+10, "PhilipsTV_StartPHILIPS", $hash);  
		}

		readingsSingleUpdate($hash,"state","wait of initializing",1);
   	}
   	else{
	   	return "too few parameters: define <name> PhilipsTV <Parameter>"; #ToDo Text noch verbessern
   	}
    
  	return undef;
}

sub PhilipsTV_StartPHILIPS {
    my ($hash) = @_;
    my $name = $hash->{NAME};

	if(PhilipsTV_setupControlpoint($hash)){
		unless(PhilipsTV_startSearch($hash)){
            readingsSingleUpdate($hash,"state","error Upnp",1);
            return undef;
        }
	}  	
	readingsSingleUpdate($hash,"state","Upnp is running",1);
	return undef;
}

sub PhilipsTV_StartTV {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    $hash->{helper}{pair}{RUN} = INITIALIZE;
    $hash->{helper}{on}{RUN} = 2;
    $hash->{helper}{upnp}{STATE} = INITIALIZE;
	
	if(AttrVal($name,"deviceID","") ne ""){
	    # Attr überschreibt    
	    readingsSingleUpdate($hash,"deviceID",AttrVal($name,"deviceID",""),1);
	}
	if(AttrVal($name,"authKey","") ne ""){
	    # Attr überschreibt    
	    readingsSingleUpdate($hash,"authKey",AttrVal($name,"authKey",""),1);
	}
	# macAdress kommt auch von Upnp - nein leider nicht mehr zuverlässig
	if(AttrVal($name,"macAddress","") ne ""){
	    # Attr überschreibt  
	    # ToDo MAC Address prüfen  
	    $hash->{MAC} = AttrVal($name,"macAddress","");
	}
	
	return undef;
}

sub PhilipsTV_Read {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	my $err;
  
  	# $name ist vom Socket!
  
  	my $phash = $hash->{phash};
  	my $cp = $phash->{helper}{upnp}{controlpoint};
  	
#   	local $SIG{__WARN__} = sub {
#     	my ($called_from) = caller(0);
#     	my $wrn_text = shift;
#     	$wrn_text =~ m/^(.*?)\sat\s.*?$/;
#     	Log3 $name, 1, $phash->{NAME}.": <Read> Socked ".$name." - handleOnce failed: $1";
#     	#Log3 $name, 1, $phash->{NAME}.": <Read> Socked ".$name." - handleOnce failed: called from> ".$called_from.", warn text> ".$wrn_text;
#   	};
  
  	eval {
  		local $SIG{__WARN__} = sub { die $_[0] };
  		
    	$cp->handleOnce($hash->{CD}); #UPnP 1x ausführen, weil etwas auf den Sockets angekommen ist
  	};
  
  	if($@) {
  		$err = $@;
  		$err =~ m/^(.*?)\sat\s(.*?)$/;
     	Log3 $name, 2, $phash->{NAME}.": <Read> socket ".$name." - handleOnce failed: $1";
     	Log3 $name, 5, $phash->{NAME}.": <Read> socket ".$name." - handleOnce failed at: $2";
  	}
  
   	# Log bei global verbose 5 - Vorsicht, sind evtl. viele Aufrufe durch Multicast!  
  
  	my $socket = $hash->{CD};
	my $self = $cp;
	
	if ($socket == $self->{_searchSocket}) {
		Log3 $name, 5, $phash->{NAME}.": <Read> socket ".$name." - received search response, $@";
	}
	elsif ($socket == $self->{_ssdpMulticastSocket}) {
		Log3 $name, 5, $phash->{NAME}.": <Read> socket ".$name." - received ssdp event needed to get information about removed or added devices, $@";
	}
	elsif ($socket == $self->{_subscriptionSocket}) {
		Log3 $name, 5, $phash->{NAME}.": <Read> socket ".$name." - received event caused by subscription, $@";
	}

  return undef;
}

sub PhilipsTV_Shutdown {
    my ($hash, $arg) = @_; 
	my $name = $hash->{NAME};
	
	Log3 $name, 5, $name.": <Shutdown> called";
	
	#kein UNSUBSCIBE senden wenn Subscription Port gesetzt, läuft ins timeout, bzw. der Subscription Port wird wieder benutzt
	if(AttrVal($hash->{NAME}, 'subscriptionPort', 0) == 0 ){
		PhilipsTV_StopControlPoint($hash) if ($hash->{SUBTYPE} eq "PHILIPS");
	}
    
    RemoveInternalTimer($hash);
    
    select(undef, undef, undef, 2);
    
    return undef;
}

sub PhilipsTV_DelayedShutdown {
    my ($hash) = @_; 
	my $name = $hash->{NAME};
	
	Log3 $name, 5, $name.": <DelayedShutdown> called";

    RemoveInternalTimer($hash);
	
	#kein UNSUBSCIBE senden wenn Subscription Port gesetzt, läuft ins timeout, bzw. der Subscription Port wird wieder benutzt
	if(AttrVal($hash->{NAME}, 'subscriptionPort', 0) == 0 ){
		InternalTimer(gettimeofday()+1, "PhilipsTV_StopControlPoint", $hash) if ($hash->{SUBTYPE} eq "PHILIPS");
		#Time wegen DelayedShutdown
	}
        
    return 1; #Anmeldung, das DelayedShutdown notwendig
}


sub PhilipsTV_Undef {
    my ($hash, $arg) = @_; 
	my $name = $hash->{NAME};
	
	Log3 $name, 5, $name.": <Undef> called ";
    
    BlockingKill($hash->{helper}{upnp}{RUNNING_PID}) if(exists($hash->{helper}{upnp}{RUNNING_PID}));
    
    #UNSUBSCIBE senden
    PhilipsTV_StopControlPoint($hash) if ($hash->{SUBTYPE} eq "PHILIPS");
     
    #HttpUtils_Close($hash);  #nur wenn ich es verwenden sollte
   
    RemoveInternalTimer($hash);
    
    select(undef, undef, undef, 1);
    
    return undef;
}

sub PhilipsTV_Delete {
	my ($hash, $name) = @_;
	
	Log3 $name, 5, $name.": <Delete> called ";
	
	#ToDo testen
	if ($hash->{SUBTYPE} eq "PHILIPS"){
		# Erst alle TVs löschen
		for my $TVs (PhilipsTV_getAllTVs($hash)) {
			Log3 $name, 5, $name.": <Delete> called to delete ".$TVs->{NAME};
			CommandDelete(undef, $TVs->{NAME});
		}
		
		# Etwas warten...
		select(undef, undef, undef, 1);	
	}	

	
	# Das Entfernen des PhilipsTV-Devices selbst übernimmt Fhem
	return undef;
}

sub PhilipsTV_Get {
	my ($hash, $name, $opt, @args) = @_;

    return "\"get $name\" needs at least one argument" unless(defined($opt));

    Log3 $name, 5, $name.": <Get> called for $name : msg = $opt";
    
	return if($hash->{helper}{pair}{RUN}); # wenn pairing

	my $dump;
	my $usage = "Unknown argument $opt, choose one of ";
	
	if($hash->{SUBTYPE} eq "PHILIPS"){
	    
	    return;
	    
# 		if(AttrVal($name, "expert", 0) == 0){
# 			$usage = "Unknown argument $opt, choose one of ";
# 		}
# 		else{
# 			$usage = "Unknown argument $opt, choose one of ";
# 		}
	}
	elsif($hash->{SUBTYPE} eq "TV"){
	    
	    #ToDo offline beachten
	    unless($hash->{STATE} eq "offline"){
    	    if(PhilipsTV_isPairingNecessary($hash) == PAIR_OK){
    	        $usage .= "VolumeUpnp:noArg VolumeEndpoint:noArg Powerstate:noArg AmbihueStatus:noArg ";
    	    }
    	    elsif(PhilipsTV_isPairingNecessary($hash) == PAIR_NOT_NECESSARY){
    	        # ToDo noch rausbekommen, was möglich
    	        $usage .= "";
    	    }
        }
	   	if(AttrVal($name, "expert", 0) == 1){
	   		#nur parentId "all"
		   	my $favoriteListsNames = "";
	   		if(defined($hash->{helper}{channelList}{favoriteListsNames})){
				$favoriteListsNames = "FavoriteList:".$hash->{helper}{channelList}{favoriteListsNames}." ";
	   		}
			$usage .= "ChannelDb:noArg ChannelList:noArg CurrentApp:noArg CurrentChannel:noArg ".$favoriteListsNames."NotifyChanges:noArg Applications:noArg Input:noArg NetworkInfo:noArg SystemRequest:noArg isOnline:noArg MacAddress:noArg MenuStructure:noArg MenuItem";
		}
	}
	else{
	    return;
	}
	
	#ToDo Zustand $hash->{STATE} = "wait of initializing" erkennen.
	
	(Log3 $name, 3, $hash->{TYPE}.": get ".$name." $opt ".join " ",@args) if($opt ne "?");

	
	# ToDo Readings ausgeben
	if ($opt =~ /^(state|)$/){
		if(defined($hash->{READINGS}{$opt})){
			return $hash->{READINGS}{$opt}{VAL};
		}
		else{
			return "no such reading: $opt";
		}
	} 
	elsif($opt eq "ChannelDb"){
		if(PhilipsTV_Request($hash, "channeldb")){
			$hash->{helper}{channeldb} = $hash->{helper}{lastResponse};
		    PhilipsTV_convertBool($hash->{helper}{channeldb});
		    local $Data::Dumper::Deepcopy = 1;
			$dump = Dumper($hash->{helper}{channeldb});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
            return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{channeldb})){
	        if(%{$hash->{helper}{channeldb}}){
			    PhilipsTV_convertBool($hash->{helper}{channeldb});
			    local $Data::Dumper::Deepcopy = 1;
				$dump = Dumper($hash->{helper}{channeldb});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
        }
		return "No data available: $opt";
	}	
	elsif($opt eq "ChannelList"){
		if(PhilipsTV_ChannelDbRequest($hash,1)){
			$dump = Dumper($hash->{helper}{channelList});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
            return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{channelList})){
	        if(%{$hash->{helper}{channelList}}){
				$dump = Dumper($hash->{helper}{channelList});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}	
	elsif($opt eq "FavoriteList"){
		$args[0] =~ s/\x{00C2}\x{00A0}/ /g; 	#kommt von den &nbsp; muss wieder weg
		$args[0] = decode('utf-8', $args[0]);	#Unicode 
		my ($favoriteList);
		
	    if($args[0] ne "all"){
	        if(defined($hash->{helper}{channelList}{favoriteLists})){
		        if(@{$hash->{helper}{channelList}{favoriteLists}}){
					($favoriteList) = grep { $args[0] eq $_->{ownId} } @{$hash->{helper}{channelList}{favoriteLists}};
		 			if($favoriteList){
						if(exists($favoriteList->{id})){
							$commands{get}{favoriteLists}{path} = "channeldb/tv/favoriteLists/".$favoriteList->{id};
						}
					}
				}
			}
		}
		else{
			$commands{get}{favoriteLists}{path} = "channeldb/tv/favoriteLists/all";
		}

		if(PhilipsTV_Request($hash, "favoriteLists")){
			$dump = Dumper($hash->{helper}{lastResponse});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
            return "actual data:\n".$dump;
        }
		elsif($favoriteList){
				$dump = Dumper($favoriteList);
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
		}
		return "No data available: $opt";
	}	
	elsif($opt eq "CurrentChannel"){
		if(PhilipsTV_CurrentChannelRequest($hash)){
			$dump = Dumper($hash->{helper}{currentChannel});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{currentChannel})){
	        if(%{$hash->{helper}{currentChannel}}){
				$dump = Dumper($hash->{helper}{currentChannel});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}	
	elsif($opt eq "Applications"){
		if(PhilipsTV_ApplicationsRequest($hash,1)){
			$dump = Dumper($hash->{helper}{applications});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{applications})){
	        if(%{$hash->{helper}{applications}}){
				$dump = Dumper($hash->{helper}{applications});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	   }
		return "No data available: $opt";
	}	
	elsif($opt eq "CurrentApp"){
		if(PhilipsTV_Request($hash, "currentApp")){
		    $hash->{helper}{currentApp} = $hash->{helper}{lastResponse};
			$dump = Dumper($hash->{helper}{currentApp});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{currentApp})){
	        if(%{$hash->{helper}{currentApp}}){
				$dump = Dumper($hash->{helper}{currentApp});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}	
	elsif($opt eq "VolumeUpnp"){
		if(PhilipsTV_GetVolume($hash) && PhilipsTV_GetMute($hash) && PhilipsTV_GetAllowedTransforms($hash)){
			return 	"Volume: ".$hash->{helper}{volume}{Master}{current}."\n".
					"Mute  : ".$hash->{helper}{volume}{Master}{mute}."\n\n".
					"Transform\n  minimum: ".$hash->{helper}{volume}{Master}{minimum}."\n".
					"  maximum: ".$hash->{helper}{volume}{Master}{maximum}."\n".
					"  step   : ".$hash->{helper}{volume}{Master}{step}; 
		}
		return "No data available: $opt";
	}	
	elsif($opt eq "VolumeEndpoint"){
		if(PhilipsTV_VolumeRequest($hash)){
		    #{"muted":false,"current":12,"min":0,"max":60}
			return 	"Volume: ".$hash->{helper}{volume}{Endpoint}{current}."\n".
					"Mute  : ".$hash->{helper}{volume}{Endpoint}{muted}."\n\n".
					"Transform\n  minimum: ".$hash->{helper}{volume}{Endpoint}{min}."\n".
					"  maximum: ".$hash->{helper}{volume}{Endpoint}{max}; 
		}
		return "No data available: $opt";
	}	
	elsif($opt eq "Powerstate"){
		if(PhilipsTV_PowerRequest($hash)){
		    #{"powerstate":"StandbyKeep|Standby|On"}
            return $hash->{helper}{powerstate}{powerstate};
        } 
		return "No data available: $opt";
	}
	elsif($opt eq "AmbihueStatus"){
		if(PhilipsTV_Request($hash, "ambihue_status")){
		    #{"power":"Off"}
		    $hash->{helper}{ambihue_status} = $hash->{helper}{lastResponse};
		    readingsSingleUpdate($hash, "ambihueStatus", $hash->{helper}{ambihue_status}{power},1);
            return $hash->{helper}{ambihue_status}{power};
        }
		return "No data available: $opt";
	}
	elsif($opt eq "SystemRequest"){
		if(PhilipsTV_SystemRequest($hash)){
		    #{"notifyChange":"http","menulanguage":"German","name":"65OLED805\\/12","country":"Germany","serialnumber_encrypted":"4XQKpNf8MHLn\\/JUj9XSF4mx4e7ZpBfIXJg2GOTB3Khc=\\n","softwareversion_encrypted":"rRUTiXEBR40A5zhdF0xGGbUQUI+wLSi9dYBJ0h4VE2fazeqbTl9DZelAVLX4lOaC\\n","model_encrypted":"82FrWxjPxLwGwC9tc5pi1VFUOjDvMY7PDO5g38HwqbI=\\n","deviceid_encrypted":"KbdsYA7S\\/fbreZEnoVyGeAm+BRIkUTo4HPEEguq+H2o=\\n","nettvversion":"9.0.0","epgsource":"broadcast","api_version":{"Major":6,"Minor":4,"Patch":0},"featuring":{"jsonfeatures":{"editfavorites":["TVChannels","SatChannels"],"recordings":["List","Schedule","Manage"],"ambilight":["LoungeLight","Hue","Ambilight","HueStreaming"],"menuitems":["Setup_Menu"],"textentry":["not_available"],"applications":["TV_Apps","TV_Games","TV_Settings"],"pointer":["not_available"],"inputkey":["key"],"activities":["intent"],"channels":["preset_string"],"mappings":["server_mapping"]},"systemfeatures":{"tvtype":"consumer","content":["dmr","pvr"],"tvsearch":"intent","pairing_type":"digest_auth_pairing","secured_transport":"true","companion_screen":"true"}},"os_type":"MSAF_2019_P"}
			$dump = Dumper($hash->{helper}{system});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{system})){
	        if(%{$hash->{helper}{system}}){
				$dump = Dumper($hash->{helper}{system});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}	
	elsif($opt eq "isOnline"){
		if(PhilipsTV_isOnline($hash,1)){
            return "online";
        }
		return "offline";
	}		
	elsif($opt eq "MacAddress"){
		#ToDo über NotifyChanges bzw. NetworkInfo abfragen und in Attr eintragen.
		#Sollte aber mit der ersten Verbindung in Internal MAC vorhanden sein
	    my $mac = $hash->{MAC};
		if(defined($mac)){
			# Daten in Attr speichern
			if((AttrVal($name,"macAddress","") eq "") || (AttrVal($name,"macAddress","") ne $mac)){
            	CommandAttr(undef,$name." macAddress ".$mac);
			}
            return $mac;
        }
		return "No data available: $opt";
	}			
	elsif($opt eq "NetworkInfo"){
	    if(PhilipsTV_NetworkInfoRequest($hash)){
			$dump = Dumper($hash->{helper}{network}{devices});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{network}{devices})){
	        if(@{$hash->{helper}{network}{devices}}){
				$dump = Dumper($hash->{helper}{network}{devices});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}
	elsif($opt eq "NotifyChanges"){
	    if(PhilipsTV_NotifyChangeRequest($hash)){
			$dump = Dumper($hash->{helper}{notifychange});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{notifychange})){
	        if(%{$hash->{helper}{notifychange}}){
				$dump = Dumper($hash->{helper}{notifychange});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}
	elsif($opt eq "Input"){
		if(PhilipsTV_Request($hash, "input")){
		    $hash->{helper}{input} = $hash->{helper}{lastResponse};
			$dump = Dumper($hash->{helper}{input});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
            return $dump;
        }
		return "No data available: $opt";
	}
	elsif($opt eq "MenuStructure"){
		if(PhilipsTV_menuitemsSettingsStructureRequest($hash,1)){
			$dump = Dumper($hash->{helper}{menuitemsSettingsStructure});
			$dump =~ s{\A\$VAR\d+\s*=\s*}{};
           	return "actual data:\n".$dump;
        }
		elsif(defined($hash->{helper}{menuitemsSettingsStructure})){
	        if(%{$hash->{helper}{menuitemsSettingsStructure}}){
				$dump = Dumper($hash->{helper}{menuitemsSettingsStructure});
				$dump =~ s{\A\$VAR\d+\s*=\s*}{};
	            return "stored data:\n".$dump;
	        }
	    }
		return "No data available: $opt";
	}
	elsif($opt eq "MenuItem"){
		if(defined($hash->{helper}{menuitemsSettingsStructure})){
		    if(defined($args[0])){
		    	# {"nodes" => [{"nodeid" => 0000000000}]}
		    	# AUDIO_OUT_DELAY
		    	# SWITCH_ON_WITH_WIFI_WOWLAN
		    	# SWITCH_ON_WITH_CHROMECAST
		    	# MUTE_SCREEN
		    	
		    	my $search = "org.droidtv.ui.strings.R.string.MAIN_".$args[0];
		    	my $result = PhilipsTV_menuitemsSearch(\%{$hash->{helper}{menuitemsSettingsStructure}},$search);
		    	
		    	if(defined($result)){
			    	$commands{post}{menuitemsSettingsCurrent}{body}{nodes}[0]{nodeid} = $result->{node_id};
									
					#Debug(Dumper($commands{post}{menuitemsSettingsCurrent}));
						
					if(PhilipsTV_Request($hash, "menuitemsSettingsCurrent")){
					    #{}
					    $hash->{helper}{menuitemsSettingsCurrent} = $hash->{helper}{lastResponse};
					    PhilipsTV_convertBool($hash->{helper}{menuitemsSettingsCurrent});
					    local $Data::Dumper::Deepcopy = 1;
						$dump = Dumper($hash->{helper}{menuitemsSettingsCurrent});
						$dump =~ s{\A\$VAR\d+\s*=\s*}{};
			            return $dump;
			        }
		    	}
		    	return "no item available: $opt $args[0]";
			}
		}
		return "No data available: $opt";
	}
			
	return $usage; 
}

sub PhilipsTV_Set {
	my ($hash, $name, $cmd, @args) = @_;

	return "\"set $name\" needs at least one argument" unless(defined($cmd));

	Log3 $name, 5, $name.": <Set> called for $name : msg = $cmd";
	
	my $usage = "Unknown argument $cmd, choose one of ";

	my $channel = "";
	my $channelName = "";
	my $applications = "";

	my $defaultChannelList = AttrVal($name, "defaultChannelList", "all");
    my $defaultFavoriteList = AttrVal($name, "defaultFavoriteList", "");

	
	if($hash->{SUBTYPE} eq "PHILIPS"){
	    $usage .= "RescanNetwork:noArg StartUpnpSearch:noArg";
	}
	elsif($hash->{SUBTYPE} eq "TV"){
        # Remote
        unless(defined($hash->{helper}{commands}{remote})){
            # Liste für Set erstellen, nur beim ersten mal
            my @matchRemote = ();
            foreach my $commandRemote (keys(%{$commands{post}})) {
                next unless(defined($commands{post}{$commandRemote}{path})); 
                push(@matchRemote, $commandRemote) if($commands{post}{$commandRemote}{path} =~ /^input.*$/);
            }
            $hash->{helper}{commands}{remote} = join(',', sort @matchRemote);
        }
        
        # Ambilight	    
        unless(defined($hash->{helper}{commands}{ambilight})){
            # Liste für Set erstellen, nur beim ersten mal
            my @matchAmbilight = ();
            foreach my $commandAmbilight (keys(%{$commands{post}})) {
                next unless(defined($commands{post}{$commandAmbilight}{path})); 
                if($commands{post}{$commandAmbilight}{path} =~ /^ambilight.*$/){
                	#ToDo "ambilight_" aus command entfernen, oder in def schon                
                	$commandAmbilight =~ s/ambilight_//g;
                	push(@matchAmbilight, $commandAmbilight); 
                }
            }
            $hash->{helper}{commands}{ambilight} = join(',', sort @matchAmbilight);
        }
        
        # Channels
        my ($channelList);
		if($defaultFavoriteList eq ""){
	        if(defined($hash->{helper}{channelList}{channelLists})){
		        if(@{$hash->{helper}{channelList}{channelLists}}){
					($channelList) = grep { $defaultChannelList eq $_->{id} } @{$hash->{helper}{channelList}{channelLists}};
					
		 			if($channelList){
						($channelName = "ChannelName:".$channelList->{names}." ") if(exists($channelList->{names}));
						($channel = "Channel:".$channelList->{presets}." ") if(exists($channelList->{presets}));
					}
				}
	        }
        }
        else{
	        if(defined($hash->{helper}{channelList}{favoriteLists})){
		        if(@{$hash->{helper}{channelList}{favoriteLists}}){
					($channelList) = grep { ($defaultFavoriteList eq $_->{id}) || ($defaultFavoriteList eq $_->{ownId}) || ($defaultFavoriteList eq $_->{name}) } @{$hash->{helper}{channelList}{favoriteLists}};
					
		 			if($channelList){
						($channelName = "ChannelName:".$channelList->{names}." ") if(exists($channelList->{names}));
						($channel = "Channel:".$channelList->{presets}." ") if(exists($channelList->{presets}));
					}
				}
	        }
        }
        
        #Applications
        if(defined($hash->{helper}{applications}{applications})){
	        if(@{$hash->{helper}{applications}{applications}}){
				($applications = "Application:".$hash->{helper}{applications}{labels}." ") if(exists($hash->{helper}{applications}{labels}));
			}
        }
        
        
		# State
        unless($hash->{STATE} eq "offline"){
    	    if(PhilipsTV_isPairingNecessary($hash) == PAIR_UNDEF){
    	        $usage .= "on:noArg off:noArg toggle:noArg ";
    	    }
    	    elsif(PhilipsTV_isPairingNecessary($hash) == PAIR_OK){
    	    	# ToDo Volume Slider :slider,0,1,100 - Grenzen aus allowed Transform
    	    	# ToDo HDMI Anzahl aus Menü Struktur ermitteln
    	    	#Channel:".$presetsList." ChannelName:".$namesList." 
    	        $usage .= "on:noArg off:noArg toggle:noArg ".$channel."".$channelName."".$applications."Remote:".$hash->{helper}{commands}{remote}." Ambilight:".$hash->{helper}{commands}{ambilight}." Volume:slider,0,1,100 HDMI:1,2,3,4 MenuItem PairRequest:noArg ";
    	    }
    	    elsif(PhilipsTV_isPairingNecessary($hash) == PAIR_NECESSARY){
    	        $usage .= "PairRequest:noArg ";
    	    }
    	    elsif(PhilipsTV_isPairingNecessary($hash) == PAIR_NOT_NECESSARY){
    	        # ToDo noch rausbekommen, was möglich
    	        $usage .= "on:noArg off:noArg toggle:noArg ";
    	    }
	    }
	    else{
	        $usage .= "on:noArg off:noArg toggle:noArg ";
	    }
	   	if(AttrVal($name, "expert", 0) == 1){
			$usage .= "WOL:noArg PowerOnCromecast:noArg Power:On,Standby Standby:noArg";
		}
	
	    $usage = "Unknown argument $cmd, choose one of Pin" if($hash->{helper}{pair}{RUN});
	}
	else{
	    return;
	}


	(Log3 $name, 3, $hash->{TYPE}.": set ".$name." $cmd ".join " ",@args) if($cmd ne "?");

	if ($cmd =~ /^(on|off|toggle)$/){
		if($cmd eq "on"){	#
            PhilipsTV_On($hash);
		}
		elsif($cmd eq "off"){
			PhilipsTV_Off($hash);
		}
		elsif($cmd eq "toggle"){
           if($hash->{STATE} eq "on"){
                PhilipsTV_Off($hash);
            }
            else{
                PhilipsTV_On($hash);
            }
		}
		#Log3 $name, 3, $name.": set $name $cmd";
		return (undef, 1);
	}
	
	#ToDo Offline?
	
	elsif($cmd eq "PairRequest"){
		PhilipsTV_PairRequest($hash);
		return (undef, 1);
	}
	elsif($cmd eq "Pin"){
	    # Pin auf Zahlen und Zeichenanzahl prüfen
	    $args[0] =~ s/^\s+|\s+$//g;
	    if((length($args[0]) == 4) && ($args[0] =~ /^\d+$/)){
    		PhilipsTV_PairGrant($hash, $args[0]);
    		return (undef, 1);
		}
		return "Wrong argument for Pin!";
	}
	elsif($cmd eq "Remote"){
	    # Todo Suche verbessern
	    #Debug($args[0]. " " .$hash->{helper}{commands}{remote});
	    my @listRemote = split( /,/, $hash->{helper}{commands}{remote});
	    if ($args[0] ~~ @listRemote){  
		    PhilipsTV_Request($hash, $args[0]);
		    return (undef, 1);
		}
		return "Wrong argument for Remote!";
	}	
	elsif($cmd eq "Ambilight"){
	    # Todo Suche verbessern
	    #Debug($args[0]. " " .$hash->{helper}{commands}{remote});
	    my @listAmbi = split( /,/, $hash->{helper}{commands}{ambilight});
	    if ($args[0] ~~ @listAmbi){  
		    PhilipsTV_Request($hash, "ambilight_".$args[0]);
		    return (undef, 1);
		}
		return "Wrong argument for Ambilight!";
	}	
	elsif($cmd eq "Power"){
	    #ToDo nur Test
	    #$commands{post}{power}{body}{powerstate} = $args[0];
	    if($args[0] eq "On"){
			PhilipsTV_Request($hash, "powerstate_on");
		}
		if($args[0] eq "On"){
			PhilipsTV_Request($hash, "powerstate_standby");
		}
		PhilipsTV_PowerRequest($hash);#PhilipsTV_Get($hash, $name, "Powerstate");
		return (undef, 1);
	}	
	elsif($cmd eq "Volume"){
	    # wird per Upnp gehandelt
	    $args[0] =~ s/^\s+|\s+$//g;
	    # Grenzen aus AllowedTransforms
	    if(PhilipsTV_GetAllowedTransforms($hash)){
		    if(($args[0] >= $hash->{helper}{volume}{Master}{minimum}) && ($args[0] <= $hash->{helper}{volume}{Master}{maximum}) && ($args[0] =~ /^\d+$/)){
				PhilipsTV_SetVolume($hash, $args[0]);
				return (undef, 1);
			}
	    }
		return "Wrong argument for Volume or no Upnp communication!";
	}
	elsif($cmd eq "HDMI"){
	    $args[0] =~ s/^\s+|\s+$//g;
	    if(($args[0] >= 1) && ($args[0] <= 4) && ($args[0] =~ /^\d+$/)){
			PhilipsTV_HDMIRequest($hash, $args[0]);
			return (undef, 1);
		}
		return "Wrong argument for HDMI!";
	}	
	elsif($cmd eq "Channel"){
	    $args[0] =~ s/^\s+|\s+$//g;						#Trim Leerzeichen
	    
 		if ($args[0] =~ qr/^[0-9]{1,4}$/) {
 			if($defaultFavoriteList eq ""){
		        if(defined($hash->{helper}{channelList}{channelLists})){
			        if(@{$hash->{helper}{channelList}{channelLists}}){
						my ($p) = grep { $defaultChannelList eq $_->{id} } @{$hash->{helper}{channelList}{channelLists}};
						
			 			if($p){
							if(exists($p->{Channel})){
								return "Channellist is empty!" unless(@{$p->{Channel}});
								#"body" => {"channel" => {"ccid" => 0,"preset" => "","name" => ""},"channelList" => {"id" => "","version" => ""}},
								$commands{post}{setChannel}{body}{channelList}{id} = $p->{id};
								$commands{post}{setChannel}{body}{channelList}{version} = $p->{version};
								
								my @list = @{$p->{Channel}};
								my ($pp) = grep { $args[0] == $_->{preset} } @list;
					 			
					 			if($pp){
						 			$commands{post}{setChannel}{body}{channel}{ccid} = $pp->{ccid};
						 			$commands{post}{setChannel}{body}{channel}{name} = $pp->{name};
						 			$commands{post}{setChannel}{body}{channel}{preset} = $pp->{preset};
					 				
					 				PhilipsTV_Request($hash, "setChannel");
					 				
					 				InternalTimer(gettimeofday()+3, "PhilipsTV_CurrentChannelRequest", $hash);	#
					 				
									return (undef, 1);
								}
				 			}
						}
					}
				}
			}
			else{	
	        	if(defined($hash->{helper}{channelList}{favoriteLists})){
			        if(@{$hash->{helper}{channelList}{favoriteLists}}){
						my ($p) = grep { ($defaultFavoriteList eq $_->{id}) || ($defaultFavoriteList eq $_->{ownId}) || ($defaultFavoriteList eq $_->{name}) } @{$hash->{helper}{channelList}{favoriteLists}};
						
			 			if($p){
							if(exists($p->{channels})){
								return "Channellist is empty!" unless(@{$p->{channels}});
								#"body" => {"channel" => {"ccid" => 0,"preset" => "","name" => ""},"channelList" => {"id" => "","version" => ""}},
								$commands{post}{setChannel}{body}{channelList}{id} = $p->{id};
								$commands{post}{setChannel}{body}{channelList}{version} = $p->{version};
								
								my @list = @{$p->{channels}};
								my ($pp) = grep { $args[0] == $_->{preset} } @list;
					 			
					 			if($pp){
						 			$commands{post}{setChannel}{body}{channel}{ccid} = $pp->{ccid};
						 			$commands{post}{setChannel}{body}{channel}{name} = $pp->{name};
						 			$commands{post}{setChannel}{body}{channel}{preset} = $pp->{preset};
					 				
					 				PhilipsTV_Request($hash, "setChannel");
					 				
					 				InternalTimer(gettimeofday()+3, "PhilipsTV_CurrentChannelRequest", $hash);	#
					 				
									return (undef, 1);
								}
				 			}
						}
					}
				}
			}	
		}
		return "Wrong argument for Channel!";
	}	
	elsif($cmd eq "ChannelName"){
		my $channelName = join " ",@args;
	    $channelName =~ s/^\s+|\s+$//g;					#Trim Leerzeichen 
		$channelName =~ s/\x{00C2}\x{00A0}/ /g; 		#kommt von den &nbsp; muss wieder weg
		$channelName = decode('utf-8', $channelName);	#Unicode 

		 if($defaultFavoriteList eq ""){
	        if(defined($hash->{helper}{channelList}{channelLists})){
		        if(@{$hash->{helper}{channelList}{channelLists}}){
					my ($p) = grep { $defaultChannelList eq $_->{id} } @{$hash->{helper}{channelList}{channelLists}};
					
		 			if($p){
						if(exists($p->{Channel})){
							return "Channellist is empty!" unless(@{$p->{Channel}});
							#"body" => {"channel" => {"ccid" => 0,"preset" => "","name" => ""},"channelList" => {"id" => "","version" => ""}},
							$commands{post}{setChannel}{body}{channelList}{id} = $p->{id};
							$commands{post}{setChannel}{body}{channelList}{version} = $p->{version};
							
							my @list = @{$p->{Channel}};
							my ($pp) = grep { $channelName eq $_->{name} } @list;
				 			
				 			if($pp){
					 			$commands{post}{setChannel}{body}{channel}{ccid} = $pp->{ccid};
					 			$commands{post}{setChannel}{body}{channel}{name} = $pp->{name};
					 			$commands{post}{setChannel}{body}{channel}{preset} = $pp->{preset};
				 				
				 				PhilipsTV_Request($hash, "setChannel");
				 				
				 				InternalTimer(gettimeofday()+3, "PhilipsTV_CurrentChannelRequest", $hash);	#
				 				
								return (undef, 1);
							}
			 			}
					}
				}
			}
		}
		else{
        	if(defined($hash->{helper}{channelList}{favoriteLists})){
		        if(@{$hash->{helper}{channelList}{favoriteLists}}){
					my ($p) = grep { ($defaultFavoriteList eq $_->{id}) || ($defaultFavoriteList eq $_->{ownId}) || ($defaultFavoriteList eq $_->{name}) } @{$hash->{helper}{channelList}{favoriteLists}};
					
		 			if($p){
						if(exists($p->{channels})){
							return "Channellist is empty!" unless(@{$p->{channels}});
							#"body" => {"channel" => {"ccid" => 0,"preset" => "","name" => ""},"channelList" => {"id" => "","version" => ""}},
							$commands{post}{setChannel}{body}{channelList}{id} = $p->{id};
							$commands{post}{setChannel}{body}{channelList}{version} = $p->{version};
							
							my @list = @{$p->{channels}};
							my ($pp) = grep { $channelName eq $_->{name} } @list;
				 			
				 			if($pp){
					 			$commands{post}{setChannel}{body}{channel}{ccid} = $pp->{ccid};
					 			$commands{post}{setChannel}{body}{channel}{name} = $pp->{name};
					 			$commands{post}{setChannel}{body}{channel}{preset} = $pp->{preset};
				 				
				 				PhilipsTV_Request($hash, "setChannel");
				 				
				 				InternalTimer(gettimeofday()+3, "PhilipsTV_CurrentChannelRequest", $hash);	#
				 				
								return (undef, 1);
							}
			 			}
					}
				}
			}
		}
		return "Wrong argument for ChannelName!";
	}	
	elsif($cmd eq "Application"){
		my $applicationName = join " ",@args;
	    $applicationName =~ s/^\s+|\s+$//g;						#Trim Leerzeichen 
		$applicationName =~ s/\x{00C2}\x{00A0}/ /g; 			#kommt von den &nbsp; muss wieder weg
		$applicationName = decode('utf-8', $applicationName);	#Unicode 

        if(defined($hash->{helper}{applications}{applications})){
	        if(@{$hash->{helper}{applications}{applications}}){
				return "Applications is empty!" unless(@{$hash->{helper}{applications}{applications}});
				# {"path" => "activities/launch","body" => {"intent" => {"component" => { "className" => "xxx","packageName" => "xxx"}},"action" => "empty"}}, 
				my ($p) = grep { $applicationName eq $_->{label} } @{$hash->{helper}{applications}{applications}};
				 	
			 	if($p){
					$commands{post}{launchApplication}{body}{intent}{component}{className} = $p->{intent}{component}{className};
					$commands{post}{launchApplication}{body}{intent}{component}{packageName} = $p->{intent}{component}{packageName};
					$commands{post}{launchApplication}{body}{intent}{action} = $p->{intent}{action};
	 				
	 				PhilipsTV_Request($hash, "launchApplication");
					return (undef, 1);
			 	}		
			}
		}
		return "Wrong argument for Application!";
	}		
	elsif($cmd eq "WOL"){
	    #ToDo nur Test
		PhilipsTV_WOL($hash);
		return (undef, 1);
	}		
	elsif($cmd eq "PowerOnCromecast"){
	    #ToDo nur Test
		PhilipsTV_PowerOnCromecast($hash);
		return (undef, 1);
	} 	
	elsif($cmd eq "Standby"){
	    #ToDo nur Test
		PhilipsTV_Request($hash, "standby");
		return (undef, 1);
	}  	
	elsif($cmd eq "MenuItem"){
		if(defined($hash->{helper}{menuitemsSettingsStructure})){
		    if(ref($hash->{helper}{menuitemsSettingsStructure}) eq 'HASH'){
			    if(defined($args[0])){
			    	$args[1] =~ s/^\s+|\s+$//g;
			    	if($args[1] =~ /^\d+$/){
						#{"path" => "menuitems/settings/update","body" => {"values" => [{"value" => {"Nodeid" => 0000000000,"data" => {"selected_item" => 0}}}]}},
				    	# AUDIO_OUT_DELAY
				    	# SWITCH_ON_WITH_WIFI_WOWLAN
				    	# SWITCH_ON_WITH_CHROMECAST
				    	# MUTE_SCREEN
				    	
				    	my $search = "org.droidtv.ui.strings.R.string.MAIN_".$args[0];
				    	my $result = PhilipsTV_menuitemsSearch(\%{$hash->{helper}{menuitemsSettingsStructure}},$search);
			    		
			    		if(defined($result)){
				    		$commands{post}{menuitemsSettingsUpdate}{body}{values}[0]{value}{Nodeid} = $result->{node_id}; 
				    		
				    		# ToDo test ob selected_item möglich ist
				    		$commands{post}{menuitemsSettingsUpdate}{body}{values}[0]{value}{data}{selected_item} = $args[1];
							
							#Debug(Dumper($commands{post}{menuitemsSettingsUpdate}));
							
							PhilipsTV_Request($hash, "menuitemsSettingsUpdate");
							return (undef, 1);
			    		}
			    		return "No item available: MenuItem $args[0]";
			    	}
				}
			}
		}
		
		return "Wrong argument or no data for MenuItem!";
	}  	 
	elsif($cmd eq "RescanNetwork"){
		PhilipsTV_rescanNetwork($hash);
		return (undef, 1);
	}
	elsif($cmd eq "StartUpnpSearch"){
		PhilipsTV_startSearch($hash);
		return (undef, 1);
	}	
	
 	return $usage;
}

sub PhilipsTV_Attr {
	my ($cmd,$name,$attr_name,$attr_value) = @_;
	# $cmd can be "del" or "set"
	# $name is device name
	# $attr_name and $attr_value are Attribute name and value
	my $hash = $main::defs{$name};
	
	$attr_value = "" if (!defined $attr_value);
	
	Log3 $name, 5, $name.": <Attr> called for $attr_name : value = $attr_value";
	
	(Log3 $name, 3, $hash->{TYPE}.": attr ".$name." $cmd $attr_name $attr_value") if(($cmd ne "?") && ($init_done));
	
	if($cmd eq "set") {
        if($attr_name eq "xxx") {
			# value testen
			#if($attr_value !~ /^yes|no$/) {
			#    my $err = "Invalid argument $attr_value to $attr_name. Must be yes or no.";
			#    Log 3, "PhilipsTV: ".$err;
			#    return $err;
			#}""
		}
		elsif($attr_name eq "deviceID"){
		    # ToDo value testen
		    readingsSingleUpdate($hash, "deviceID", $attr_value, 1);
		}
		elsif($attr_name eq "authKey"){
		    # ToDo value testen
		    readingsSingleUpdate($hash, "authKey", $attr_value, 1);
		}
		elsif($attr_name eq "macAddress"){
			$attr_value =~ s/^\s+|\s+$//g;
		    if(PhilipsTV_checkMAC($attr_value)){
		    	$hash->{MAC} = $attr_value;
		    }
		    else{
		    	return "Invalid argument $attr_value to $attr_name. Must be a valid MAC address.";
		    }
		}
		elsif($attr_name eq "renewSubscription"){
		    # ToDo value testen

		}
		elsif($attr_name eq "rescanNetworkInterval"){
		    # ToDo value testen
		    InternalTimer(gettimeofday() + 1, "PhilipsTV_rescanNetwork", $hash);
		}
		elsif($attr_name eq "startUpnpSearchInterval"){
		    # ToDo value testen
			InternalTimer(gettimeofday() + 1, "PhilipsTV_startSearch", $hash);
		}
		elsif($attr_name eq "pollingInterval"){
		    # ToDo value testen
			InternalTimer(gettimeofday() + 1, "PhilipsTV_GetStatus", $hash);
		}
		elsif($attr_name eq "defaultChannelList"){
		    # ToDo value testen
			PhilipsTV_ChannelDbRequest($hash,1) if ($hash->{STATE} eq "on");
		}
		elsif($attr_name eq "defaultFavoriteList"){
		    # ToDo value testen
			PhilipsTV_ChannelDbRequest($hash,1) if ($hash->{STATE} eq "on");
		}
		elsif($attr_name eq "acceptedModelName"){
		    # ToDo value testen
			$hash->{acceptedModelName} = $attr_value;
		}
		
		
		
		

	}
	elsif($cmd eq "del"){
		#default wieder herstellen
		if($attr_name eq "rescanNetworkInterval"){
		    RemoveInternalTimer($hash, "PhilipsTV_rescanNetwork");
		}
		elsif($attr_name eq "startUpnpSearchInterval"){
		    RemoveInternalTimer($hash, "PhilipsTV_startSearch");
		}
		elsif($attr_name eq "pollingInterval"){
		    RemoveInternalTimer($hash, "PhilipsTV_GetStatus");
		}
		elsif($attr_name eq "acceptedModelName"){
		    $hash->{acceptedModelName} = "Philips TV DMR";
		}

	}
	return undef;
}

sub PhilipsTV_Notify {
  my ($hash, $dev_hash) = @_;
  my $name = $hash->{NAME}; # own name / hash
  
  Log3 $name, 5, $name.": <Notify> called";

  return "" if(IsDisabled($name)); # Return without any further action if the module is disabled

  my $devName = $dev_hash->{NAME}; # Device that created the events

  my $events = deviceEvents($dev_hash,1);
  return if( !$events );

  if($devName eq $name){
      foreach my $event (@{$events}) {
        $event = "" if(!defined($event));
    
        Log3 $name, 3, $name.": event ausgelöst - " . $event;
    
        # Examples:
        # $event = "readingname: value" 
        # or
        # $event = "INITIALIZED" (for $devName equal "global")
        #
        # processing $event with further code
      }
  }
}


################################################################################
# PHILIPS ######################################################################
################################################################################







################################################################################
# TV ###########################################################################
################################################################################

sub PhilipsTV_GetStatus {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <GetStatus> called";
    
	if(PhilipsTV_isOnline($hash)){
	    unless(defined($hash->{helper}{system}{ok})){
	        unless(PhilipsTV_SystemRequest($hash)){
	            Log3 $name, 3, $name.": system request unsuccessful!"; 
	        }
	    }

		#Test delete($hash->{helper}{system}{system}{notifyChange});

		# NotifyChangeRequest
		if(defined($hash->{helper}{system}{system}{notifyChange})){
			if($hash->{helper}{system}{system}{notifyChange} eq "http"){
		    	unless(PhilipsTV_NotifyChangeRequest($hash)){                                  
		            Log3 $name, 3, $name.": Notifychange request unsuccessful!";
		        } 
			}
		}
		else{
			$hash->{helper}{powerstate}{notifychangeState} = 0;
			$hash->{helper}{network}{notifychangeState} = 0;
			$hash->{helper}{currentChannel}{notifychangeState} = 0;
		}
		
		#nur wenn Pairing OK
		if(PhilipsTV_isPairingNecessary($hash) == PAIR_OK){
			my $dataLoaded = 1;
			# PowerRequest
			unless($hash->{helper}{powerstate}{notifychangeState}){
		    	unless(PhilipsTV_PowerRequest($hash)){ 
		            Log3 $name, 3, $name.": PowerRequest request unsuccessful!";
		        } 
			}
			# NetworkInfoRequest
			unless($hash->{helper}{network}{notifychangeState}){
		    	unless(PhilipsTV_NetworkInfoRequest($hash)){
		            Log3 $name, 3, $name.": NetworkInfoRequest request unsuccessful!";
		        } 
			}
			# CurrentChannelRequest
			unless($hash->{helper}{currentChannel}{notifychangeState}){
		    	unless(PhilipsTV_CurrentChannelRequest($hash)){
		            Log3 $name, 3, $name.": CurrentChannelRequest request unsuccessful!";
		        } 
			}
			# ChannelDbRequest
	    	unless(PhilipsTV_ChannelDbRequest($hash)){
	    		$dataLoaded = 0;                                  
	            Log3 $name, 3, $name.": ChannelList request unsuccessful!";
	        } 
			# ApplicationsRequest
	    	unless(PhilipsTV_ApplicationsRequest($hash)){
	    		$dataLoaded = 0;                                  
	            Log3 $name, 3, $name.": Applications request unsuccessful!";
	        } 
	        # menuitemsSettingsStructure
	        unless(PhilipsTV_menuitemsSettingsStructureRequest($hash)){
	        	$dataLoaded = 0;
	        	Log3 $name, 3, $name.": menuitemsSettingsStructure request unsuccessful!";
	        }
	        # wenn alle Daten geladen sind
	        if(($dataLoaded) && ($hash->{STATE} eq "on")){
	        	readingsSingleUpdate($hash,"data","loaded",1);
	        }
	        else{
	        	readingsSingleUpdate($hash,"data","notready",1);
	        }
		}
    }

    Log3 $name, 4, $name.": <GetStatus> state of Upnp: ".$upnpState{$hash->{helper}{upnp}{STATE}}." - state of STATE: ".$hash->{STATE};
    
    # nur einmal ausführen, nachdem mit upnp gefunden bzw. wenn Polling aktiv
    if(($hash->{helper}{upnp}{STATE} == FOUND) || ($hash->{helper}{upnp}{STATE} == FIRSTFOUND)){
  	
	  	#Polling
	  	if(AttrVal($name,"pollingInterval",30) > 0){
	  		Log3 $name, 4, $name.": <GetStatus> succesfull setup of polling - interval" if($hash->{helper}{upnp}{STATE} == FIRSTFOUND);
	  		InternalTimer(gettimeofday() + 10 + int(rand(AttrVal($name,"pollingInterval",30))), "PhilipsTV_GetStatus", $hash);
		}
	  	else{
	  		Log3 $name, 4, $name.": <GetStatus> succesfull setup of polling - off";
		} 	
		
	  	# FIRSTFOUND beenden für Senderliste
	  	$hash->{helper}{upnp}{STATE} = FOUND;
    } 
    
    # mehrfach ausführen bis offline, nachdem mit upnp abgemeldet
    if(($hash->{helper}{upnp}{STATE} == REMOVED) && ($hash->{STATE} ne "offline")){
        InternalTimer(gettimeofday() + 5 + int(rand(10)), "PhilipsTV_GetStatus", $hash);
        Log3 $name, 4, $name.": <GetStatus> wait of state offline";

    }
    
    # Log, um zu sehen wann TV offline geht nach ausschalten
    if(($hash->{helper}{upnp}{STATE} == REMOVED) && ($hash->{STATE} eq "offline") && (AttrVal($name, "expert", 0))){
    	my $diff = gettimeofday() - $hash->{helper}{upnp}{timestamp}{removed};
    	Log3 $name, 3, $name.": offline after ".$diff."s of upnp removed" ;
    }
   
    return;
}    

sub PhilipsTV_On {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <On> called";
    
    readingsSingleUpdate($hash,"state","set-online",1);
    
	# prüfen ob online
	unless(PhilipsTV_isOnline($hash)){
        # wenn nicht dann WOL
        PhilipsTV_WOL($hash);
        
        #$hash->{helper}{ON}{RUN} = 2 unless(defined($hash->{helper}{ON}{RUN})); #
         
        unless($hash->{helper}{on}{RUN} <= 0){
            InternalTimer(gettimeofday()+2, "PhilipsTV_On", $hash);
            $hash->{helper}{on}{RUN} --; 
        }
        else{
            $hash->{helper}{on}{RUN} = 2;
            RemoveInternalTimer($hash, "PhilipsTV_On");
            readingsSingleUpdate($hash,"state","offline",1);
            readingsSingleUpdate($hash,"data","notready",1);
            Log3 $name, 1, $name.": Error while power on, is wasn't possible to switch on";
        }
        return undef;
	}
	$hash->{helper}{on}{RUN} = 2;
	RemoveInternalTimer($hash, "PhilipsTV_On");
	
	if(PhilipsTV_SystemRequest($hash)){                                  
    	# einschalten mit Powerstate oder ChromeCast
    	#$commands{post}{power}{body}{powerstate} = "On";
    	if(PhilipsTV_Request($hash, "powerstate_on")){ 
            PhilipsTV_PowerRequest($hash);
        }
        else{
            #ToDo Testen ob PowerOnCromecast etwas nützt 
            PhilipsTV_PowerOnCromecast($hash);
        }
        
        # UPnP Suche starten nach 20s, weil TV sich manchmal nicht selbst meldet
		my $hashAccount = PhilipsTV_getHashOfAccount($hash);
		InternalTimer(gettimeofday() + 20, "PhilipsTV_startSearch", $hashAccount) ;
    } 
    return undef;
}

sub PhilipsTV_Off {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <Off> called";
	# prüfen ob online
	if(PhilipsTV_isOnline($hash)){
    	#$commands{post}{power}{body}{powerstate} = "Standby";
    	if(PhilipsTV_Request($hash, "powerstate_standby")){ 
            PhilipsTV_PowerRequest($hash);
        }
    }
    return undef;
}

sub PhilipsTV_isOnline {
    my ( $hash,$force ) = @_;
    my $name = $hash->{NAME};

    ($force = 0) if(!defined($force));

    Log3 $name, 5, $name.": <isOnline> called";
    
    my $count = 1;      # Anzahl Pings
    my $timeout = AttrVal($name, "pingTimeout", 1);    # Timeout in s
    
    # Ping hat unterschidliche Argumente und Antworten
    # macos -> darwin
    # Linux -> linux
	# Windows -> MSWin32
	# AIX -> aix
	# Solaris -> solaris
	my $ping;
    if ($^O eq "darwin"){
    	$ping = qx(ping -c $count -t $timeout $hash->{IP} 2>&1);
    }
    else{
    	$ping = qx(ping -c $count -w $timeout $hash->{IP} 2>&1);
    }

    if(defined($ping) and $ping ne ""){
        chomp $ping;
        Log3 $name, 5, $name.": <isOnline> IP:". $hash->{IP} . " - ping command returned with output:\n" . $ping; 
        
        unless($ping =~ m/(100%|100.0%)/){
        	if(($hash->{STATE} eq "offline") || ($hash->{STATE} eq "set-online")){ 
            	readingsSingleUpdate($hash,"state","online",1); 
            	Log3 $hash, 3, $name.": state of isOnline - online"; 
            	
            	PhilipsTV_RefreshScreen($hash) if(!$force);
            	
        	}
            return 1;    
        }
    }
	if($hash->{STATE} ne "set-online"){
		
		#Upnp auf removed, wenn TV nicht per upnp abgemeldet
		if(defined($hash->{helper}{upnp}{device})){	
			#PhilipsTV_removedDevice($hash,$hash->{helper}{upnp}{device});
			RemoveInternalTimer($hash, 'PhilipsTV_renewSubscriptions');
			if(exists($hash->{helper}{upnp}{RUNNING_PID})){
				BlockingKill($hash->{helper}{upnp}{RUNNING_PID});
				delete($hash->{helper}{upnp}{RUNNING_PID});
			}
		
			delete($hash->{helper}{upnp}{device});
			$hash->{helper}{upnp}{STATE} = REMOVED; 
			$hash->{helper}{upnp}{timestamp}{removed} = gettimeofday(); 	# für GetStatus Log
			Log3 $hash, 4, $name.": <isOnline> Upnp device delete, because it wasn't removed!";						
		}
		
		readingsSingleUpdate($hash,"state","offline",1); 
		readingsSingleUpdate($hash,"data","notready",1);
		PhilipsTV_RefreshScreen($hash) if(!$force);
	}
	
    Log3 $hash, 3, $name.": state of isOnline - offline";
  
    return undef;
}

sub PhilipsTV_WOL {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    my $address = '255.255.255.255';
    my $port = 9;
    my $mac_addr = $hash->{MAC}; #ReadingsVal($name, "macAddress", undef);

	Log3 $name, 5, $name.": <WOL> called";

    # ToDo $mac_addr prüfen?

    if(defined($mac_addr)){
        my $sock = new IO::Socket::INET( Proto => 'udp' ) or die "socket : $!";
        if(!$sock){
            Log3 $name, 1, $name.": Can't create WOL socket";
            return undef;
        }
    
        my $ip_addr = inet_aton($address);
        my $sock_addr = sockaddr_in( $port, $ip_addr );
        $mac_addr =~ s/://g;
        my $packet =
          pack( 'C6H*', 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, $mac_addr x 16 );
    
        setsockopt($sock, SOL_SOCKET, SO_BROADCAST, 1) or die "setsockopt : $!";
    	
    	Log3 $name, 3, $name.": Waking up by sending Wake-On-Lan magic package to $mac_addr";
    	
        send( $sock, $packet, 0, $sock_addr ) or die "send : $!";
        close($sock);
    }
    else{
        Log3 $name, 1, $name.": Error wrong mac address!";
    }    
    return 1;
}

sub PhilipsTV_PowerOnCromecast {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <PowerOnCromecast> called";
    
    #http://192.168.2.76:8008/apps/ChromeCast
    
	my $uri;
	my $protocol    = "http://";
	my $ip          = $hash->{IP};
	my $port        = "8008";
	my $path        = "apps/ChromeCast";
	my $response;

	$uri = $protocol . $ip . ":" . $port . "/apps/ChromeCast";
	$client->timeout(3);
    #$client->agent(USER_AGENT);
    
    Log3 $name, 5, $name.": <SystemChangeRequest> URL:".$uri." send:\n".
      	"## Content ###########\n"."---";
    
    $response = $client->post($uri);
    
    if(defined($response)){
	    if($response->is_success){
		    Log3 $name, 5, $name.": <PowerOnCromecast> URL:".$uri." get HTTP returned:\n".
		             "## Response ##########\n".Dumper($response)."\n".
		             "## Data ##############\n".$response->decoded_content."\n".
		             "## Content-Type ######\n".$response->content_type."\n".
		             "## Content-length ####\n".$response->content_length."\n";
	    
			return 1;
	    }
	    else{	
	        Log3 $name, 4, $name.": Error while HTTP requesting URL:".$uri." - Error - ".$response->status_line;
	    }
    }
    else{	
        Log3 $name, 1, $name.": Error while HTTP requesting URL:".$uri;
    }
    return undef;    
}  

sub PhilipsTV_isPairingNecessary {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 5, $name.": <isPairingNecessary> called";
    
    if(defined($hash->{helper}{system}{ok})){
        if(defined($hash->{system_pairingType})){
            if($hash->{system_pairingType} eq "digest_auth_pairing"){
                if(defined(ReadingsVal($name, "deviceID", undef)) && defined(ReadingsVal($name, "authKey", undef))){
                    return 1; #Pairing OK
                }
                else{
                    return 2; #Pairing notwendig
                }
            }
        }
        #if(ReadingsVal($name,"system_apiVersion",undef) < 6){
#         if($hash->{helper}{system}{api} < 6){
#             return 3; #Pairing nicht notwendig
#         }
    }
    return 0; #Pairing unklar
}

################################################################################
# Requests #####################################################################
################################################################################

sub PhilipsTV_PowerRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <PowerRequest> called";
    
	if(PhilipsTV_Request($hash, "powerstate")){
	    #{"powerstate":"StandbyKeep|Standby|On"}
	    readingsBeginUpdate($hash);
    	    $hash->{helper}{powerstate} = $hash->{helper}{lastResponse};
    	    readingsBulkUpdateIfChanged($hash, "Powerstate", $hash->{helper}{powerstate}{powerstate});
            if($hash->{helper}{powerstate}{powerstate} eq "On"){
                readingsBulkUpdateIfChanged($hash, "state", "on");
            }
            elsif($hash->{helper}{powerstate}{powerstate} eq "StandbyKeep"){
                readingsBulkUpdateIfChanged($hash, "state", "standby-keep");
            }
             elsif($hash->{helper}{powerstate}{powerstate} eq "Standby"){
                readingsBulkUpdateIfChanged($hash, "state", "standby");
            }
           else{
                # wäre ungewöhnlich
                readingsBulkUpdateIfChanged($hash, "state", $hash->{helper}{powerstate}{powerstate});
            }
        readingsEndUpdate($hash, 1);
        Log3 $hash, 5, $name.": <PowerRequest> state of powerstate - ".$hash->{helper}{powerstate}{powerstate};
        return 1;
    } 
	return undef;
}

sub PhilipsTV_VolumeRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <VolumeRequest> called";
    
	if(PhilipsTV_Request($hash, "volume")){
	    #{"muted":false,"current":12,"min":0,"max":60}
	    $hash->{helper}{volume}{Endpoint} = $hash->{helper}{lastResponse};
	    
	    #JSON Bool wandeln	    
	    my $bool = $hash->{helper}{volume}{Endpoint}->{muted};
	    ($bool)? ($hash->{helper}{volume}{Endpoint}{muted} = 1) : ($hash->{helper}{volume}{Endpoint}{muted} = 0);
	    
# 	    readingsBeginUpdate($hash);
# 		    readingsBulkUpdateIfChanged($hash, "Volume", $hash->{helper}{volume}{current});
# 		    readingsBulkUpdateIfChanged($hash, "Mute", $hash->{helper}{volume}{muted});
# 		readingsEndUpdate($hash, 1);
#		Log3 $hash, 3, $name.": state of volume - ".$hash->{helper}{volume}{Endpoint}{current};
		
        return 1;
    }
	return undef;
}

sub PhilipsTV_HDMIRequest($$) {
    my ( $hash, $hdmi ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <HDMIRequest> called";
    
    $commands{post}{google_assistant}{body}{intent}{extras}{query} = "HDMI ".$hdmi;
    
	if(PhilipsTV_GoogleRequest($hash)){
		Log3 $hash, 3, $name.": state of HDMI - set to HDMI ".$hdmi;
        return 1;
    }
	return undef;
}


sub PhilipsTV_GoogleRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <GoogleRequest> called";
    
	if(PhilipsTV_Request($hash, "google_assistant")){
	    $hash->{helper}{google} = $hash->{helper}{lastResponse};

#		Log3 $hash, 3, $name.": state of google - ".$hash->{helper}{google};
        return 1;
    }
	return undef;
}


sub PhilipsTV_SystemRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <SystemRequest> called";
    
    #my @ports = (1926);
	#my @apiVersions = (6);
	
	my $uri;
	#my $protocol = "https://";
	my $ip = $hash->{IP} ;
	my $response;
	#my $protokolR;
	#my $portR;
	my $timeout = AttrVal($name, "requestTimeout", 2);    		# Timeout in s

    $uri = PROTOCOL . $ip . ":" . PORT . "/" . API . "/system";
    $client->timeout($timeout);
    #$client->agent(USER_AGENT);
    #$client->ssl_opts(SSL_fingerprint => 'sha1$96A52B034901D9580C9ECFD4B6C9442EC483C3EB');
    
    Log3 $name, 5, $name.": <SystemChangeRequest> URL:".$uri." send:\n".
    	"## Content ###########\n"."---";
    
    $response = $client->get($uri);
	
	if(defined($response)){
	    if($response->is_success){
            Log3 $name, 5, $name.": <SystemRequest> URL:".$uri." get HTTP returned:\n".
                     "## Response ##########\n".Dumper($response)."\n".
                     "## Data ##############\n".$response->decoded_content."\n".
                     "## Content-Type ######\n".$response->content_type."\n".
                     "## Content-length ####\n".$response->content_length."\n";

            if(($response->content_type eq "application/json") && ($response->content_length > 0)){
            	# testen ob JSON OK ist
            	eval{
            		$hash->{helper}{system}{system} = decode_json($response->decoded_content);
            	};
            	if($@){
            		my $err = $@;
			  		$err =~ m/^(.*?)\sat\s(.*?)$/;
			    	Log3 $name, 4, $name.": Error while JSON decode: $1 ";
			    	Log3 $name, 5, $name.": <SystemChangeRequest> JSON decode at: $2";
			    	return undef;
            	}
            	# testen ob Referenz vorhanden
            	if((ref($hash->{helper}{system}{system}) ne 'HASH') && (ref($hash->{helper}{system}{system}) ne 'ARRAY')){
			    	Log3 $name, 4, $name.": Error, response isn't a reference!";
			    	return undef;
            	}
            	
				#API Version ermitteln
# 				if(exists($hash->{helper}{system}{system}{api_version}{Major})){
# 					$apiVersion = $hash->{helper}{system}{system}{api_version}{Major};
# 				}
# 				else{
# 					Log3 $name, 1, $name . ": could not find a valid API version! Will try to use '" . $apiVersion . "'";
# 				}
# 				
# 				#Port & Protokoll ermitteln
# 				$protokolR = "http://";
# 				$portR = "1925"; 
# 				 
# 				if(exists($hash->{helper}{system}{system}{featuring}{systemfeatures}{pairing_type})){
# 					if($hash->{helper}{system}{system}{featuring}{systemfeatures}{pairing_type} eq "digest_auth_pairing"){
#         				$protokolR = "https://";
#         				$portR = "1926"; 
# 					}
# 				}
#     			$hash->{helper}{system}{api} = $apiVersion;
#     			$hash->{helper}{system}{protokoll} = $protokolR;
#     			$hash->{helper}{system}{port} = $portR;
#     			
#         			$hash->{system_api} = $apiVersion;
#         			$hash->{system_protokoll} = $protokolR;
#         			$hash->{system_port} = $portR;

				$hash->{helper}{system}{ok} = 1;

     			$hash->{system_apiVersion} = $hash->{helper}{system}{system}{api_version}{Major} . "." . $hash->{helper}{system}{system}{api_version}{Minor} . "." . $hash->{helper}{system}{system}{api_version}{Patch} if(defined($hash->{helper}{system}{system}{api_version}{Major}));
    			$hash->{system_model} = $hash->{helper}{system}{system}{name} if(defined($hash->{helper}{system}{system}{name}));
    			$hash->{system_osType} = $hash->{helper}{system}{system}{os_type} if(defined($hash->{helper}{system}{system}{os_type}));
    			$hash->{system_pairingType} = $hash->{helper}{system}{system}{featuring}{systemfeatures}{pairing_type} if(defined($hash->{helper}{system}{system}{featuring}{systemfeatures}{pairing_type}));
    			$hash->{system_notifyChange} = $hash->{helper}{system}{system}{notifyChange} if(defined($hash->{helper}{system}{system}{notifyChange}));
				$hash->{nettvversion} = $hash->{helper}{system}{system}{nettvversion} if(defined($hash->{helper}{system}{system}{nettvversion}));
   	        			
    			return 1;                     	
            }
        	else{	
        	    Log3 $name, 1, $name.": Error while HTTPS requesting URL:".$uri." - no JSON data!";
        	}
	    }
	    else{	
	        Log3 $name, 4, $name.": Error while HTTPS requesting URL:".$uri." - Error - ".$response->status_line;
	    }
    }
    else{	
        Log3 $name, 1, $name.": Error while HTTPS requesting URL:".$uri;
	}
	return undef;
}

sub PhilipsTV_NotifyChangeRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <NotifyChangeRequest> called";
    
    #ToDo im SystemRequest ist angegeben welcher Art der Zugriff erfolgen kann:
    #{"notifyChange":"http","menulanguage":"German","name":"65OLED805\\/12","country":"Germany",...
    
	my $uri;
	my $protocol 	= "https://";
	my $ip 			= $hash->{IP} ;
	my $port        = "1926"; 
#	my $apiVersion  = $hash->{helper}{system}{api}; 
	my $response;
	my $channelListName = "";
	my $timeout = AttrVal($name, "requestTimeout", 2);    		# Timeout in s


    $uri = $protocol . $ip . ":" . $port . "/" . API . "/notifychange";
    
    my $content = encode_json(\%notifychange);
    
    $client->timeout($timeout);
    #$client->agent(USER_AGENT);
    
    Log3 $name, 5, $name.": <NotifyChangeRequest> URL:".$uri." send:\n".
            "## Content ###########\n".$content;
    
    $response = $client->post($uri, Content => $content);

	if(defined($response)){
	    if($response->is_success){
		    Log3 $name, 5, $name.": <NotifyChangeRequest> URL:".$uri." get HTTP returned:\n".
		             "## Response ##########\n".Dumper($response)."\n".
		             "## Data ##############\n".$response->decoded_content."\n".
		             "## Content-Type ######\n".$response->content_type."\n".
		             "## Content-length ####\n".$response->content_length."\n";
	
	        if(($response->content_type eq "application/json") && ($response->content_length > 0)){
            	# testen ob JSON OK ist
            	eval{
            		$hash->{helper}{notifychange} = decode_json($response->decoded_content);
            	};
            	if($@){
			  		my $err = $@;
			  		$err =~ m/^(.*?)\sat\s(.*?)$/;
			    	Log3 $name, 4, $name.": Error while JSON decode: $1 ";
			    	Log3 $name, 5, $name.": <NotifyChangeRequest> JSON decode at: $2";
			    	return undef;
            	}
            	# testen ob Referenz vorhanden
            	if((ref($hash->{helper}{notifychange}) ne 'HASH') && (ref($hash->{helper}{notifychange}) ne 'ARRAY')){
			    	Log3 $name, 4, $name.": Error, response isn't a reference!";
			    	return undef;
            	}
	
					
#					"notification" => {
#										"context" 				=> {},
#										"network/devices" 		=> [],
#										"input/textentry" 		=> {},
#										"input/pointer" 		=> {},
#										"channeldb/tv" 			=> {},
#										"activities/tv" 		=> {},
#										"activities/current" 	=> {},
#										"applications/version" 	=> "",
#										"applications" 			=> {},
#										"system/epgsource" 		=> {},
#										"powerstate" 			=> {},
#										"system/nettvversion" 	=> "",
#										"system/storage/status" => "",
#										"recordings/list" 		=> {},
#										"companionlauncher" 	=> {}
	
				# powerstate
			    readingsBeginUpdate($hash);
			    
			    	#Test delete($hash->{helper}{notifychange}{powerstate});
			    
			    	# wenn Powerstate in notifychange vorhanden ist - https://forum.fhem.de/index.php/topic,130172.msg1247968.html#msg1247968
		    	    if(defined($hash->{helper}{notifychange}{powerstate})){
			    	    $hash->{helper}{powerstate} = $hash->{helper}{notifychange}{powerstate};
			    	    $hash->{helper}{powerstate}{notifychangeState} = 1;
			    	    
			    	    readingsBulkUpdateIfChanged($hash, "Powerstate", $hash->{helper}{powerstate}{powerstate});
			            if($hash->{helper}{powerstate}{powerstate} eq "On"){
			                readingsBulkUpdateIfChanged($hash, "state", "on");
			            }
			            elsif($hash->{helper}{powerstate}{powerstate} eq "StandbyKeep"){
			                readingsBulkUpdateIfChanged($hash, "state", "standby-keep");
			            }
			             elsif($hash->{helper}{powerstate}{powerstate} eq "Standby"){
			                readingsBulkUpdateIfChanged($hash, "state", "standby");
			            }
			           else{
			                # wäre ungewöhnlich
			                readingsBulkUpdateIfChanged($hash, "state", $hash->{helper}{powerstate}{powerstate});
			            }
			   		}
			   		else{
			   			$hash->{helper}{powerstate}{notifychangeState} = 0;
			   		}

			    	#Test delete($hash->{helper}{notifychange}{"network/devices"});
			    
					# wenn network in notifychange vorhanden ist
					if(defined($hash->{helper}{notifychange}{"network/devices"})){				
						$hash->{helper}{network}{devices} = $hash->{helper}{notifychange}{"network/devices"};
						$hash->{helper}{network}{notifychangeState} = 1;
						
						if(@{$hash->{helper}{network}{devices}}){
							foreach my $device (@{$hash->{helper}{network}{devices}}) {
								if($device->{id} eq "wifi0"){
									$hash->{system_WOLonWifi} = $device->{"wake-on-lan"};
									if($hash->{system_WOLonWifi} eq "Enabled"){
										$hash->{MAC} = $device->{"mac"};
										if((AttrVal($name,"macAddress","") eq "") || (AttrVal($name,"macAddress","") ne $hash->{MAC})){
						            		CommandAttr(undef,$name." macAddress ".$hash->{MAC});
										}
									}
								}
								elsif($device->{id} eq "eth0"){
									$hash->{system_WOLonETH} = $device->{"wake-on-lan"};
									if($hash->{system_WOLonETH} eq "Enabled"){
										($hash->{MAC} = $device->{"mac"}) ;
										if((AttrVal($name,"macAddress","") eq "") || (AttrVal($name,"macAddress","") ne $hash->{MAC})){
						            		CommandAttr(undef,$name." macAddress ".$hash->{MAC});
										}
									}
								}
						   	}
						}
						else{
							$hash->{system_WOLonWifi} = "";
							$hash->{system_WOLonETH} = "";
						}
					}
					else{
						$hash->{helper}{network}{notifychangeState} = 0;
					}
										
					# Speicher 
					#$hash->{helper}{storage} = $hash->{helper}{notifychange}{"system/storage/status"}; 
					if(defined($hash->{helper}{notifychange}{"system/storage/status"})){				
						readingsBulkUpdateIfChanged($hash, "Storage", $hash->{helper}{notifychange}{"system/storage/status"});
					}
					else{
						readingsBulkUpdateIfChanged($hash, "Storage", "");
					}

			    	#Test delete($hash->{helper}{notifychange}{"activities/tv"});
					
					# wenn ChannelInfo in notifychange vorhanden ist - https://forum.fhem.de/index.php/topic,130172.msg1247968.html#msg1247968
					if(defined($hash->{helper}{notifychange}{"activities/tv"})){
						$hash->{helper}{currentChannel} = $hash->{helper}{notifychange}{"activities/tv"};
						$hash->{helper}{currentChannel}{notifychangeState} = 1;
					
						# Current Channellist Version
						if((defined($hash->{helper}{currentChannel}{channelList}{version})) && (defined($hash->{helper}{currentChannel}{channelList}{id}))){				
							readingsBulkUpdateIfChanged($hash, "CurrentChannelListVersion", $hash->{helper}{currentChannel}{channelList}{version});
							$channelListName = PhilipsTV_FavoritListName($hash,$hash->{helper}{currentChannel}{channelList}{id});
							if(defined($channelListName)){
								readingsBulkUpdateIfChanged($hash, "CurrentChannelList", $hash->{helper}{currentChannel}{channelList}{id}." - ".$channelListName);
							}
							else{
								readingsBulkUpdateIfChanged($hash, "CurrentChannelList", $hash->{helper}{currentChannel}{channelList}{id});
							}
						}
						else{
							readingsBulkUpdateIfChanged($hash, "CurrentChannelListVersion", "");
							readingsBulkUpdateIfChanged($hash, "CurrentChannelList", "");
						}
			
						# Current Channel
						if(defined($hash->{helper}{currentChannel}{channel}{preset})){				
							readingsBulkUpdateIfChanged($hash, "CurrentChannelNo", $hash->{helper}{currentChannel}{channel}{preset});
							readingsBulkUpdateIfChanged($hash, "CurrentChannelName", encode('utf-8', $hash->{helper}{currentChannel}{channel}{name}));
						}
						else{
							readingsBulkUpdateIfChanged($hash, "CurrentChannelNo", "");
							readingsBulkUpdateIfChanged($hash, "CurrentChannelName", "");
						}
					}
					else{
						$hash->{helper}{currentChannel}{notifychangeState} = 0;
					}	
		        readingsEndUpdate($hash, 1);									
				return 1;                     	
	        }
	    	else{	
	    	    Log3 $name, 1, $name.": Error while HTTP requesting URL:".$uri." - no JSON data!";
	    	}
	    }
	    else{	
	        Log3 $name, 4, $name.": Error while HTTP requesting URL:".$uri." - Error - ".$response->status_line;
	    }
	}
    else{	
        Log3 $name, 1, $name.": Error while HTTP requesting URL:".$uri;
    }
	return undef;
}

sub PhilipsTV_NetworkInfoRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <NetworkInfoRequest> called";
 
	if(PhilipsTV_Request($hash,"network")){
		#{}
		$hash->{helper}{network}{devices} = $hash->{helper}{lastResponse};
		
		if(@{$hash->{helper}{network}{devices}}){
			foreach my $device (@{$hash->{helper}{network}{devices}}) {
				if($device->{id} eq "wifi0"){
					$hash->{system_WOLonWifi} = $device->{"wake-on-lan"};
					if($hash->{system_WOLonWifi} eq "Enabled"){
						$hash->{MAC} = $device->{"mac"};
						if((AttrVal($name,"macAddress","") eq "") || (AttrVal($name,"macAddress","") ne $hash->{MAC})){
		            		CommandAttr(undef,$name." macAddress ".$hash->{MAC});
						}
					}
				}
				elsif($device->{id} eq "eth0"){
					$hash->{system_WOLonETH} = $device->{"wake-on-lan"};
					if($hash->{system_WOLonETH} eq "Enabled"){
						($hash->{MAC} = $device->{"mac"}) ;
						if((AttrVal($name,"macAddress","") eq "") || (AttrVal($name,"macAddress","") ne $hash->{MAC})){
		            		CommandAttr(undef,$name." macAddress ".$hash->{MAC});
						}
					}
				}
		   	}
		}
		else{
			$hash->{system_WOLonWifi} = "";
			$hash->{system_WOLonETH} = "";
		}
		return 1;
    }
    return undef;
}

sub PhilipsTV_CurrentChannelRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};
    
    my $channelListName = "";

    Log3 $name, 5, $name.": <CurrentChannelRequest> called";
 
	if(PhilipsTV_Request($hash, "currentChannel")){
		#{}
		$hash->{helper}{currentChannel} = $hash->{helper}{lastResponse};
		readingsBeginUpdate($hash);
			# Current Channellist Version
			if((defined($hash->{helper}{currentChannel}{channelList}{version})) && (defined($hash->{helper}{currentChannel}{channelList}{id}))){				
				readingsBulkUpdateIfChanged($hash, "CurrentChannelListVersion", $hash->{helper}{currentChannel}{channelList}{version});
				$channelListName = PhilipsTV_FavoritListName($hash,$hash->{helper}{currentChannel}{channelList}{id});
				if(defined($channelListName)){
					readingsBulkUpdateIfChanged($hash, "CurrentChannelList", $hash->{helper}{currentChannel}{channelList}{id}." - ".$channelListName);
				}
				else{
					readingsBulkUpdateIfChanged($hash, "CurrentChannelList", $hash->{helper}{currentChannel}{channelList}{id});
				}
			}
			else{
				readingsBulkUpdateIfChanged($hash, "CurrentChannelListVersion", "");
				readingsBulkUpdateIfChanged($hash, "CurrentChannelList", "");
			}

			# Current Channel
			if(defined($hash->{helper}{currentChannel}{channel}{preset})){				
				readingsBulkUpdateIfChanged($hash, "CurrentChannelNo", $hash->{helper}{currentChannel}{channel}{preset});
				readingsBulkUpdateIfChanged($hash, "CurrentChannelName", encode('utf-8', $hash->{helper}{currentChannel}{channel}{name}));
			}
			else{
				readingsBulkUpdateIfChanged($hash, "CurrentChannelNo", "");
				readingsBulkUpdateIfChanged($hash, "CurrentChannelName", "");
			}
		readingsEndUpdate($hash, 1);
		return 1;
    }
    return undef;
}

sub PhilipsTV_FavoritListName {
    my ( $hash,$id ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <FavoritListName> called";

    if(defined($hash->{helper}{channeldb}{favoriteLists})){ 
		if(@{$hash->{helper}{channeldb}{favoriteLists}}){
			my ($p) = grep { $id eq $_->{id} } @{$hash->{helper}{channeldb}{favoriteLists}};
			if($p){
				return $p->{name} if(exists($p->{name}));		#wenn normale Favoritenliste 1-8
				return $p->{medium} if(exists($p->{medium})); 	#wenn virtuelle Liste
			}
	    }
	}
    return undef;
}

sub PhilipsTV_ChannelDbRequest {
    my ( $hash, $force ) = @_;
    my $name = $hash->{NAME};
    
    ($force = 0) if(!defined($force));
    
    my $defaultChannelList = AttrVal($name, "defaultChannelList", "all");
    my $defaultFavoriteList = AttrVal($name, "defaultFavoriteList", "1");

    my $response;
    my $reload = 0;
    my ($p);

    Log3 $name, 5, $name.": <ChannelDbRequest> called";
    
    if(defined($hash->{helper}{channeldb})){
    	if((defined($hash->{helper}{currentChannel}{channelList}{version})) && (defined($hash->{helper}{currentChannel}{channelList}{id}))){
    		($p) = grep { $hash->{helper}{currentChannel}{channelList}{id} eq $_->{id} } @{$hash->{helper}{channeldb}{channelLists}};
 			if($p){
				# id vorhanden
				if($hash->{helper}{currentChannel}{channelList}{version} > $p->{version}){
					# version ist höher
					$reload = 1
				}
			}
    		($p) = grep { $hash->{helper}{currentChannel}{channelList}{id} eq $_->{id} } @{$hash->{helper}{channeldb}{favoriteLists}};
 			if($p){
				# id vorhanden
				if($hash->{helper}{currentChannel}{channelList}{version} > $p->{version}){
					# version ist höher
					$reload = 1
				}
			}
    	}
    }
    
	# wenn Version ist neu || Liste nach EIN 1x laden // force
	if($reload || ($hash->{helper}{upnp}{STATE} == FIRSTFOUND) || $force){
		if(PhilipsTV_Request($hash, "channeldb")){
			$hash->{helper}{channeldb} = $hash->{helper}{lastResponse};
			# ChannelLists einlesen wenn vorhanden
			if(@{$hash->{helper}{channeldb}{channelLists}}){
				# Liste löschen und neu erstellen
				delete($hash->{helper}{channelList});
				
				foreach my $channellist (@{$hash->{helper}{channeldb}{channelLists}}){
					$commands{get}{channelLists}{path} = "channeldb/tv/channelLists/".$channellist->{id};  #{"path" => "channeldb/tv/channelLists/all"}
			
					if(PhilipsTV_Request($hash, "channelLists")){
					    #{"version":0,"id":"all","listType":"MixedSources","medium":"mixed","operator":"None","installCountry":"Germany","Channel":[]}
					    $response = $hash->{helper}{lastResponse};
					    
					    if(@{$response->{Channel}}){
						    if($channellist->{id} eq $defaultChannelList){
						    	# default = all
							    # kommt eigentlich schon sortiert
							    # my @sorted =  sort { $a->{price} <=> $b->{price} } @data;
							    my @list = @{$response->{Channel}};
							    
							    # für Test mit Werbung
							    # my %test = ( preset => "1-1", name => "Werbung" );
							    # push @list, \%test;
							    # Debug(Dumper(@list));
							    @list = grep { $_->{preset} ne "1-1" } @list; 	# Hack, um Werbekanal zu eliminieren, stört nur, weil keine Zahl
							    # Debug(Dumper(@list));

							    my @sorted = sort { (($a->{'preset'} =~ /^(\d+)$/)[0] || 0) <=> (($b->{'preset'} =~ /^(\d+)$/)[0] || 0)} @list;
							    $response->{Channel} = \@sorted;
						    	
						    	$response->{presets} = join ',', map { $_->{preset} // () } @sorted;
						    	$response->{names} = join ',', map { $_->{name} // () } @sorted;
						    	$response->{names} =~ s/\s+/&nbsp;/g; 										#Leerzeichen ersetzen
						    	$response->{names} = encode('utf-8', $response->{names});					#Unicode enfernen
						    	
							    readingsSingleUpdate($hash, "ChannelCount", @{$response->{Channel}},1);
							    readingsSingleUpdate($hash, "ChannelList", $response->{id},1);
							    readingsSingleUpdate($hash, "ChannelListVersion", $response->{version},1);
							}
						    Log3 $hash, 3, $name.": ChannelList '".$response->{id}."' loaded with ".@{$response->{Channel}}." entries!";
						}
						else{
							if($channellist->{id} eq $defaultChannelList){
								readingsSingleUpdate($hash, "ChannelCount", 0,1);
							}
							Log3 $hash, 3, $name.": ChannelList '".$response->{id}."' is empty!";
						}
						push @{$hash->{helper}{channelList}{channelLists}}, $response;
						next;
					}
					Log3 $hash, 3, $name.": ChannelList '".$channellist->{id}."' isn't available!";
					if($channellist->{id} eq $defaultChannelList){
						readingsSingleUpdate($hash, "ChannelCount", "N/A",1);
					}
					return undef;
				}
			}
			# FavoriteLists einlesen
			if(@{$hash->{helper}{channeldb}{favoriteLists}}){
				my $count = 0;
				foreach my $favoritelists (@{$hash->{helper}{channeldb}{favoriteLists}}){
					$commands{get}{favoriteLists}{path} = "channeldb/tv/favoriteLists/".$favoritelists->{id};  #{"path" => "channeldb/tv/favoritelists/all"}
			
					if(PhilipsTV_Request($hash, "favoriteLists")){
					    #{}
					    $response = $hash->{helper}{lastResponse};
					    $response->{parentId} = $favoritelists->{parentId};
					    
						# für GET FavoriteList
						($hash->{helper}{channelList}{favoriteListsNames} = "all") if(!defined($hash->{helper}{channelList}{favoriteListsNames}));
						if(exists($favoritelists->{name})){
							$response->{ownId} = $count." : ".$favoritelists->{name};
						}
						elsif(exists($favoritelists->{medium})){
							$response->{ownId} = $count." : ".$favoritelists->{medium};
						}
						else{
							$response->{ownId} = $count;
						}
						#$hash->{helper}{channelList}{favoriteListsNames} = join ',', $hash->{helper}{channelList}{favoriteListsNames},$response->{id};
						$hash->{helper}{channelList}{favoriteListsNames} = join ',', $hash->{helper}{channelList}{favoriteListsNames},$response->{ownId};
						$hash->{helper}{channelList}{favoriteListsNames} =~ s/\s+/&nbsp;/g; 													#Leerzeichen ersetzen
						$hash->{helper}{channelList}{favoriteListsNames} = encode('utf-8', $hash->{helper}{channelList}{favoriteListsNames});	#Unicode enfernen
					    
					    if(@{$response->{channels}}){
						    # kommt eigentlich schon sortiert
						    # my @sorted =  sort { $a->{price} <=> $b->{price} } @data;
						    my @list = @{$response->{channels}};
						    @list = grep { $_->{preset} ne "1-1" } @list; 
						    my @sorted = sort { (($a->{'preset'} =~ /^(\d+)$/)[0] || 0) <=> (($b->{'preset'} =~ /^(\d+)$/)[0] || 0)} @list;
					    	
							# ToDo FavoriteList aufbereiten
							
							my ($parentChannelList) = grep { $_->{id} eq $favoritelists->{parentId} } @{$hash->{helper}{channelList}{channelLists}}; 
							if($parentChannelList){
								foreach my $favorite (@sorted) {
									my ($p) = grep { $_->{ccid} eq $favorite->{ccid} } @{$parentChannelList->{Channel}};
									if($p){
										$favorite->{name} = $p->{name};
									}
								}
								$response->{presets} = join ',', map { $_->{preset} // () } @sorted;
							    $response->{names} = join ',', map { $_->{name} // () } @sorted;
							   	$response->{names} =~ s/\s+/&nbsp;/g; 										#Leerzeichen ersetzen
							   	$response->{names} = encode('utf-8', $response->{names});					#Unicode enfernen
							}
							 
						    $response->{channels} = \@sorted;
							 
						    Log3 $hash, 3, $name.": FavoriteList '".$response->{id}."' loaded with ".@{$response->{channels}}." entries!";
						}
						else{
							Log3 $hash, 3, $name.": FavoriteList '".$response->{id}."' is empty!";
						}
						push @{$hash->{helper}{channelList}{favoriteLists}}, $response;
						$count++;
						next;
					}
					Log3 $hash, 3, $name.": FavoriteList '".$favoritelists->{id}."' isn't available!";
					return undef;
				}
			}
			
			PhilipsTV_RefreshScreen($hash) if(!$force);
			
			Log3 $name, 5, $name.": <ChannelDbRequest> ChannelList was required to load";
			return 1;
		}
		Log3 $hash, 3, $name.": ChannelDb isn't available!";
		return undef;
	}
	Log3 $name, 5, $name.": <ChannelDbRequest> ChannelList wasn't required to load";
	return 1;    
}

sub PhilipsTV_ApplicationsRequest {
    my ( $hash, $force ) = @_;
    my $name = $hash->{NAME};
    
    ($force = 0) if(!defined($force));

    Log3 $name, 5, $name.": <ApplicationsRequest> called";
    
	if((!defined($hash->{helper}{applications})) || ($hash->{helper}{upnp}{STATE} == FIRSTFOUND) || $force){
		if(PhilipsTV_Request($hash, "applications")){
			$hash->{helper}{applications} = $hash->{helper}{lastResponse};
		    # wenn etwas schief gelaufen ist
		    # ToDo müsste schon im Request abgefangen werden - testen
		    if(ref($hash->{helper}{applications}) ne 'HASH'){
		    	delete ($hash->{helper}{applications});
		    	Log3 $hash, 3, $name.": Applications not loaded!";
		    	return undef;
		    }

			# applications einlesen wenn vorhanden
			if(@{$hash->{helper}{applications}{applications}}){
				$hash->{helper}{applications}{labels} = join ',', map { $_->{label} // () } @{$hash->{helper}{applications}{applications}};
				$hash->{helper}{applications}{labels} =~ s/\s+/&nbsp;/g; 										#Leerzeichen ersetzen
				$hash->{helper}{applications}{labels} = encode('utf-8', $hash->{helper}{applications}{labels});	#Unicode enfernen
					    	
			    readingsSingleUpdate($hash, "ApplicationsCount", @{$hash->{helper}{applications}{applications}},1);
			    readingsSingleUpdate($hash, "ApplicationsVersion", $hash->{helper}{applications}{version},1);

				Log3 $hash, 3, $name.": Applications loaded with ".@{$hash->{helper}{applications}{applications}}." entries!";
			}
			else{
				readingsSingleUpdate($hash, "ApplicationsCount", "N/A",1);
				Log3 $hash, 3, $name.": Applications is empty!";
				return undef;
			}

			PhilipsTV_RefreshScreen($hash) if(!$force);
			
			Log3 $name, 5, $name.": <ApplicationsRequest> ChannelList was required to load";
			return 1;
		}
		Log3 $hash, 3, $name.": Applications isn't available!";
		return undef;
	}
	Log3 $name, 5, $name.": <ApplicationsRequest> Applications wasn't required to load";
	return 1;    
}


sub PhilipsTV_menuitemsSettingsStructureRequest {
    my ( $hash, $force ) = @_;
    my $name = $hash->{NAME};
    
    ($force = 0) if(!defined($force));
    
    Log3 $name, 5, $name.": <menuitemsSettingsStructureRequest> called";

	if((!defined($hash->{helper}{menuitemsSettingsStructure})) || ($hash->{helper}{upnp}{STATE} == FIRSTFOUND) || $force){
		if(PhilipsTV_Request($hash, "menuitemsSettingsStructure")){
		    #{}
		    $hash->{helper}{menuitemsSettingsStructure} = $hash->{helper}{lastResponse};
		    # wenn etwas schief gelaufen ist
		    # ToDo müsste schon im Request abgefangen werden - testen
		    if(ref($hash->{helper}{menuitemsSettingsStructure}) ne 'HASH'){
		    	delete ($hash->{helper}{menuitemsSettingsStructure});
		    	Log3 $hash, 3, $name.": menuitemsSettingsStructure not loaded!";
		    	return undef;
		    }
		    
		    Log3 $hash, 3, $name.": menuitemsSettingsStructure loaded!";
		    return 1;
		}
		else{
			Log3 $hash, 3, $name.": menuitemsSettingsStructure isn't available!";
			return undef;
		}
	}
	Log3 $name, 5, $name.": <menuitemsSettingsStructureRequest> menuitemsSettingsStructure wasn't required to load";
	return 1; 
}

sub PhilipsTV_PairRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <PairRequest> called";
    
    readingsSingleUpdate($hash,"state", "pairing",1);
    
    my @chars = ( "A" .. "Z", "a" .. "z", 0 .. 9 );
    $deviceData{device}{id} .= $chars[ rand @chars ] for 1 .. 16;

    
    #$deviceData{device}{id} = getDeviceID($hash);   
	$commands{post}{pair}{body} = \%deviceData;	
    if(PhilipsTV_Request($hash, "pair")){ 
		$hash->{helper}{pair} = $hash->{helper}{lastResponse}; #pair Daten merken
			
		if($hash->{helper}{pair}{error_id} =~ m/^SUCCESS$/i ){
		    # 'timeout' => 60,
            # 'error_text' => 'Authorization required',
            # 'auth_key' => '2fcddfe1cc0bcf1ab9fec7168a7c92cec576d055a989208a2187b95bf789e53e',
            # 'timestamp' => 25557
            
            # Set Pin 
            $hash->{helper}{pair}{RUN} = 1;
             # Timer starten
            InternalTimer(gettimeofday() + $hash->{helper}{pair}{timeout}, "PhilipsTV_PairRequestTimeExpired", $hash);
            
            readingsSingleUpdate($hash,"state", "pairing wait of pin",1);
			return 1;
		}
		else{
			Log3 $name, 1, $name.": Error while pair requesting no success! Error - ".$hash->{helper}{pair}{error_id}." : ".$hash->{helper}{pair}{error_text}; 
		}
    }
    return undef;
}

sub PhilipsTV_PairRequestTimeExpired {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <PairRequestTimeExpired> called";
    
    $hash->{helper}{pair}{RUN} = 0;
    readingsSingleUpdate($hash,"state", "pairing time expired",1);

    return;  
}

sub PhilipsTV_PairGrant {
    my ( $hash, $pin ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <PairGrant> called";

    $hash->{helper}{pair}{RUN} = 0;
    RemoveInternalTimer($hash, "PhilipsTV_PairRequestTimeExpired");
    
    readingsSingleUpdate($hash,"state", "pairing grant",1);
	
	# alte credencial readings merken, für den Fall die Bestätigung mit Pin geht schief
	my $deviceID = ReadingsVal($name, "deviceID", undef);
	my $authKey = ReadingsVal($name, "authKey", undef);
	
	# Readings setzen für Authentifizierung des Grant Requests
    readingsSingleUpdate($hash, "deviceID", $deviceData{device}{id}, 1);
    readingsSingleUpdate($hash, "authKey", $hash->{helper}{pair}{auth_key}, 1);
	
    # HMAC-Signatur (SHA1 Base64-encoded) aufbauen
    my $tosign = $hash->{helper}{pair}{timestamp}.$pin;
	my $secretkey = decode_base64("ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==");
	my $authsignature = hmac_sha1_hex($tosign, $secretkey);
	while (length($authsignature) % 4) {
		$authsignature .= '=';
	}
	$authsignature = encode_base64($authsignature); 
	chomp $authsignature;

    my %auth = (
    	"auth_AppId" => "1",
    	"pin" => $pin,
    	"auth_timestamp" => $hash->{helper}{pair}{timestamp},
    	"auth_signature" => $authsignature,
    );
    
    my %grant_request = ();
    $grant_request{"auth"} = \%auth;
    $grant_request{"device"} = $deviceData{"device"};

	$commands{post}{grant}{body} = \%grant_request;	
    if(PhilipsTV_Request($hash, "grant")){ 
		$hash->{helper}{grant} = $hash->{helper}{lastResponse}; #grant Daten merken
			
		if($hash->{helper}{grant}{error_id} =~ m/^SUCCESS$/i ){
            readingsSingleUpdate($hash,"state", "pairing complete",1); 
            # Daten in Attr speichern
            CommandAttr(undef,$name." deviceID ".ReadingsVal($name, "deviceID", undef));
            CommandAttr(undef,$name." authKey ".ReadingsVal($name, "authKey", undef));
			if((AttrVal($name,"macAddress","") eq "") || (AttrVal($name,"macAddress","") ne $hash->{MAC})){
            	CommandAttr(undef,$name." macAddress ".$hash->{MAC});
			}
			return 1;
		}
		else{
			Log3 $name, 1, $name.": Error while pair requesting! Error - ".$hash->{helper}{grant}{error_id}." : ".$hash->{helper}{grant}{error_text}; 
			
			# Readings wieder zurück, wenn schiefgelaufen
			readingsSingleUpdate($hash, "deviceID", $deviceID, 1);
            readingsSingleUpdate($hash, "authKey", $authKey, 1);
			$hash->{helper}{pair}{RUN} = 0;
			readingsSingleUpdate($hash,"state", "pairing error",1);
		}
    }
    return undef;
}

sub PhilipsTV_Request {
    my ( $hash, $command, $body ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <Request> called";
    
#	my $protocol    = $hash->{helper}{system}{protokoll}; 	# https://
	my $ip          = $hash->{IP};
#	my $port        = $hash->{helper}{system}{port}; 		# 1926
#	my $apiVersion  = $hash->{helper}{system}{api}; 		# 6
	my $method;
	my $path;
	my $response;
	my $error;
	my $timeout = AttrVal($name, "requestTimeout", 2);    		# Timeout in s
	
# 	# nur API = 6 zulassen, da die anderen nicht testbar sind
#     if($apiVersion != 6){
#         Log3 $name, 1, $name.": Error - API version '".$apiVersion."' not supported!";
#         return undef;
#     }
	
    # command in commands prüfen
     if(exists($commands{post}{$command})){
        $path = $commands{post}{$command}{path};
        unless(defined($body)){
            $body = encode_json($commands{post}{$command}{body}) if(exists($commands{post}{$command}{body})); 
        }
        $method = "POST";
    }
    elsif(exists($commands{get}{$command})){
        $path = $commands{get}{$command}{path};
        $method = "GET";
    }
    else{
        Log3 $name, 1, $name.": Error - '$command' - Command not exist!";
        return undef;
    }
	$request->clear;
	$request->method($method);
	$request->uri(PROTOCOL . $ip . ":" . PORT . "/" . API . "/" . $path);
	$request->header( 
	    "Content-Type"      => "application/json",
	);
	$request->content($body); 
	
	$client->credentials($ip . ":" . PORT, "XTV", ReadingsVal($name, "deviceID", undef) => ReadingsVal($name, "authKey", undef));
	#$client->ssl_opts(SSL_fingerprint => 'sha1$96A52B034901D9580C9ECFD4B6C9442EC483C3EB'); #aus restfultv_tpvision_com.crt
	#$client->agent(USER_AGENT);
	$client->timeout($timeout);
	
	$body = "not defined" if(!defined($body));
	
    Log3 $name, 5, $name.": <Request> URL:".$request->uri." send:\n".
            "## Command ###########\n".$command."\n".
            "## Body ##############\n".$body."\n".
            "## Request ###########\n".$request->as_string;
	
	for(my $i = 1;$i <= 3;$i ++){

		$response = $client->request($request);

	    if(defined($response)){
		    if($response->is_success){
			    Log3 $name, 5, $name.": <Request> URL:".$request->uri." get HTTP returned:\n".
			             "## Request ###########\n".$request->as_string.
			             "## Response ##########\n".Dumper($response)."\n".
			             "## Data ##############\n".$response->decoded_content."\n".
			             "## Content-Type ######\n".$response->content_type."\n".
			             "## Content-length ####\n".$response->content_length."\n";
	
		        if($response->content_type eq "application/json"){
			        if($response->content_length > 0){
		            	# testen ob JSON OK ist, sonst nochmal
		            	eval{
		            		$hash->{helper}{lastResponse} = decode_json($response->decoded_content);
		            	};
		            	if($@){
					  		my $err = $@;
					  		$err =~ m/^(.*?)\sat\s(.*?)$/;
					    	Log3 $name, 4, $name.": ".$i.". try of command '".$command."' - Error while JSON decode: $1 ";
					    	Log3 $name, 5, $name.": <Request> JSON decode at: $2";
					    	next;
		            	}
		            	# testen ob Referenz vorhanden, sonst nochmal
		            	if((ref($hash->{helper}{lastResponse}) ne 'HASH') && (ref($hash->{helper}{lastResponse}) ne 'ARRAY')){
					    	Log3 $name, 4, $name.": ".$i.". try of command '".$command."' - Error, response isn't a reference!";
					    	next;
		            	}
			        }
			        else{
				    	# wenn kein Content vorhanden, nochmal
				    	Log3 $name, 4, $name.": ".$i.". try of command '".$command."' - Error, response with no content!";
				    	next;
			        }
			    }
		    	else{
		    		if(AttrVal($name, "expert", 0)){
		    			# für Diagnose
		    			Log3 $name, 4, $name.": ".$i.". try of command '".$command."' - response with no content!";
		    		}
		    	    $hash->{helper}{lastResponse} = $response->decoded_content;
		    	}
		        return 1;
		    }
		    else{	
		    	$error = $response->status_line;
		    	# bei 401 Unauthorized bis zu 3x probieren, bei allen anderen Abbruch
		    	if($error =~ m/401/){
		    		Log3 $name, 4, $name.": ".$i.". try - Error while HTTP requesting URL: ".$request->uri." - Error - ".$response->status_line;
		    	}
		    	else{
		    		Log3 $name, 4, $name.": Error while HTTP requesting URL: ".$request->uri." - Error - ".$response->status_line;
		    		return undef;
		    	}
		    }
	    }
	    else{	
	        Log3 $name, 1, $name.": Error while HTTP requesting URL: ".$request->uri;
	    }
	}    
	    
    return undef;
}

################################################################################
# UPnP #########################################################################
################################################################################

# UPnP DISCOVERY ###############################################################

sub PhilipsTV_setupControlpoint {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 5, $name.": <setupControlpoint> called setup Upnp ControlPoint";
    readingsSingleUpdate($hash,"state","start setup of Upnp controlpoint",1);
  
   	my $cp;
  	my @usedonlyIPs = split(/,/, AttrVal($hash->{NAME}, 'usedonlyIPs', ''));
  	my @ignoredIPs = split(/,/, AttrVal($hash->{NAME}, 'ignoredIPs', ''));
  	my $subscriptionPort = AttrVal($hash->{NAME}, 'subscriptionPort', 0);
  	my $searchPort = AttrVal($hash->{NAME}, 'searchPort', 0);
  	my $reusePort = AttrVal($hash->{NAME}, 'reusePort', 0);
  
	eval {
		local $SIG{__WARN__} = sub { die $_[0] };
		
		$cp = UPnP::ControlPoint->new(SubscriptionURL => "/eventSub", ReusePort => $reusePort, SearchPort => $searchPort, SubscriptionPort => $subscriptionPort, MaxWait => 30, UsedOnlyIP => \@usedonlyIPs, IgnoreIP => \@ignoredIPs, LogLevel => AttrVal($hash->{NAME}, 'verbose', 0));#, EnvPrefix => 's', EnvNamespace => '');
		$hash->{helper}{upnp}{controlpoint} = $cp;
		
		PhilipsTV_addSocketsToMainloop($hash);
	};
  	if($@){
  		Log3 $name, 1, $name.": Upnp ControlPoint setup error => ".$@;
  		return undef;
  	}
  	
  	$hash->{subscriptionURL} = "<".$cp->subscriptionURL.">";
  	$hash->{acceptedModelName} = AttrVal($name, "acceptedModelName", "Philips TV DMR");
  	
  	Log3 $name, 5, $name.": <setupControlpoint> succesfull setup of Upnp ControlPoint";    
    readingsSingleUpdate($hash,"state","succesfull setup of Upnp controlpoint",1);
  	return 1;
}

sub PhilipsTV_startSearch {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    #ToDo Loglevel anpassen
    Log3 $name, 5, $name.": <startSearch> called UPnP Search";
    readingsSingleUpdate($hash,"state","start UPnP Search",1);
	
	#ControlPoint erstellt?
	if (defined($hash->{helper}{upnp}{controlpoint})) {
		#gibt es schon eine Suche, dann diese stoppen
		if(defined($hash->{helper}{upnp}{search})){
			$hash->{helper}{upnp}{controlpoint}->stopSearch($hash->{helper}{upnp}{search}{v3});
			$hash->{helper}{upnp}{controlpoint}->stopSearch($hash->{helper}{upnp}{search}{v2});
			$hash->{helper}{upnp}{controlpoint}->stopSearch($hash->{helper}{upnp}{search}{v1});
			Log3 $hash, 3, $name.": current Upnp Search - stopped";
		} 
	
		my $search;
	  	eval {
	  		local $SIG{__WARN__} = sub { die $_[0] };
	  		
	  		# Mehrere Suchen sind möglich - ControlPoint.pm
	  		
	    	$search = $hash->{helper}{upnp}{controlpoint}->searchByType('urn:schemas-upnp-org:device:MediaRenderer:3', sub { PhilipsTV_discoverCallback($hash, @_); });
	    	Log3 $name, 5, $name.": <startSearch> with type urn:schemas-upnp-org:device:MediaRenderer:3";
	    	$hash->{helper}{upnp}{search}{v3} = $search;
	    	
	    	$search = $hash->{helper}{upnp}{controlpoint}->searchByType('urn:schemas-upnp-org:device:MediaRenderer:2', sub { PhilipsTV_discoverCallback($hash, @_); });
	    	Log3 $name, 5, $name.": <startSearch> with type urn:schemas-upnp-org:device:MediaRenderer:2";
	    	$hash->{helper}{upnp}{search}{v2} = $search;
	    	
	    	$search = $hash->{helper}{upnp}{controlpoint}->searchByType('urn:schemas-upnp-org:device:MediaRenderer:1', sub { PhilipsTV_discoverCallback($hash, @_); });
	    	Log3 $name, 5, $name.": <startSearch> with type urn:schemas-upnp-org:device:MediaRenderer:1";
	    	$hash->{helper}{upnp}{search}{v1} = $search;
	    	
	  	};
	  	if($@) {
	    	Log3 $name, 1, $name.": UPnP Search failed with error $@";
	    	return undef;
	  	}
	  	Log3 $hash, 3, $name.": new Upnp search - started";
  	}
  	else{
    	Log3 $name, 1, $name.": UPnP Search failed, because no Controlpoint was setup";
    	return undef;
  	}
  	
  	#StartUpnpSearch nach x min wieder starten, wenn gewollt
  	if(AttrVal($name,"startUpnpSearchInterval",0) > 0){
  		Log3 $name, 5, $name.": <startSearch> succesfull setup of Upnp Search - interval";
  		readingsSingleUpdate($hash,"state","succesfull setup of Upnp Search - interval",1);
  		InternalTimer(gettimeofday() + (AttrVal($name,"startUpnpSearchInterval",1) * 60), "PhilipsTV_startSearch", $hash);
	}
  	else{
  		Log3 $name, 5, $name.": <startSearch> succesfull setup of Upnp Search";
  		readingsSingleUpdate($hash,"state","succesfull setup of Upnp Search",1);
	}
  	
  	return 1;
}

sub PhilipsTV_StopControlPoint {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $err;
    
    Log3 $name, 5, $name.": <StopControlPoint> called ";

	if (defined($hash->{helper}{upnp}{controlpoint})) {
		$hash->{helper}{upnp}{controlpoint}->stopSearch($hash->{helper}{upnp}{search}{v3});
		$hash->{helper}{upnp}{controlpoint}->stopSearch($hash->{helper}{upnp}{search}{v2});
		$hash->{helper}{upnp}{controlpoint}->stopSearch($hash->{helper}{upnp}{search}{v1}); 
		$hash->{helper}{upnp}{controlpoint}->stopHandling();
		my @sockets = $hash->{helper}{upnp}{controlpoint}->sockets();

	  	eval {
	  		local $SIG{__WARN__} = sub { die $_[0] };
	  		
	  		undef($hash->{helper}{upnp}{controlpoint});
	  	};
	 	if($@) {
	  		$err = $@;
#	    	Log3 $name, 2, $name.": <PhilipsTV_StopControlPoint> stop of control point failed: $1 ";
	    	
	  		$err =~ m/^(.*?)\sat\s(.*?)$/;
	     	Log3 $name, 2, $name.": <PhilipsTV_StopControlPoint> stop of control point failed: $1";
	     	Log3 $name, 5, $name.": <PhilipsTV_StopControlPoint> stop of control point failed at: $2";	    	
	  	}
			
		delete($hash->{helper}{upnp}{controlpoint});
		delete($hash->{helper}{upnp}{search});
			
		# alle Timer für Subscription anhalten
		for my $TVHash (PhilipsTV_getAllTVs($hash)) {
			RemoveInternalTimer($TVHash, 'PhilipsTV_renewSubscriptions');

			Log3 $name, 5, $name.": <StopControlPoint> RemoveInternalTimer for ".$TVHash->{NAME};
		}
  
  		# alle Sockets schließen
  		foreach my $socket (@sockets) {
    		shutdown($socket,2) if($socket);
    		close($socket) if($socket);
    
    		Log3 $name, 5, $name.": <StopControlPoint> socket $socket closed";
  	  	}
  	  	
	  	# alle UPnPSocket löschen
  	  	for my $device (PhilipsTV_getAllUPnPSockets($hash)) {
			CommandDelete(undef, $device->{NAME});
			
			Log3 $name, 5, $name.": <StopControlPoint> UPnPSocket hidden device delete ".$device->{NAME};
		}

		Log3 $name, 1, $name.": ControlPoint is successfully stopped!";
		readingsSingleUpdate($hash,"state","Upnp ControlPoint is successfully stopped",1);
		
		CancelDelayedShutdown($name); #für DelayedShutdown
	}
	else{
		Log3 $name, 5, $name.": <StopControlPoint> ControlPoint was not defined!";
	} 
}

sub PhilipsTV_discoverCallback {
  	my ($hash, $search, $device, $action) = @_;
  	my $name = $hash->{NAME};
  
  	Log3 $name, 5, $name.": <discoverCallback> device ".$device->friendlyName()." ".PhilipsTV_checkIP($device->location())." ".$device->UDN()." ".$action;

  	if($action eq "deviceAdded") {
    	PhilipsTV_addedDevice($hash, $device);
  	} 
  	elsif($action eq "deviceRemoved") {
    	PhilipsTV_removedDevice($hash, $device);
  	}
  	return undef;
}

sub PhilipsTV_addedDevice {
  	my ($hash, $device) = @_;
  	my $name = $hash->{NAME};

    Log3 $hash, 5, $name.": <addedDevice> called ";  	
  
  	my $udn = $device->UDN(); 

  	#ignoreUDNs
  	return undef if(AttrVal($name, "ignoreUDNs", "") =~ /$udn/);

  	#acceptedUDNs
  	my $acceptedUDNs = AttrVal($name, "acceptedUDNs", "");
  	return undef if($acceptedUDNs ne "" && $acceptedUDNs !~ /$udn/);
  	
  	#room 
  	my $room = AttrVal($name, "room", "PhilipsTV");
    
  	my $foundDevice = 0;
  	my @allTVs = PhilipsTV_getAllTVs($hash);
  	foreach my $TVHash (@allTVs) {
    	if($TVHash->{IP} eq PhilipsTV_checkIP($device->location())) {
      		$foundDevice = 1;
      		last;
    	}
  	}

  	if(!$foundDevice) {
  		my $filter = AttrVal($name, "acceptedModelName", "Philips TV DMR");
		if($device->modelName() =~ /\Q$filter\E/ ){
			#ToDo: Name erweitern für mehrer PHILIPS
			#ToDo muss hier UDN oder IP verwendet werden? ja, sonst nicht aus define zu finden und name änderbar

			my $uniqueDeviceName = "TV_".PhilipsTV_checkIP($device->location());
			$uniqueDeviceName =~ s/\.//g;
						
			# Device in Fhem anlegen
			my $ret = CommandDefine(undef, "$uniqueDeviceName PhilipsTV TV ".PhilipsTV_checkIP($device->location()));
			
			if(defined($ret)){Log3 $name, 5, $name.": <addedDevice> CommandDefine with result: ".$ret};
			
			CommandAttr(undef,"$uniqueDeviceName alias ".$device->friendlyName());
			#CommandAttr(undef,"$uniqueDeviceName macAddress " . uc(join( ':', substr($device->UDN(),29,12) =~ m/(\w{2})/g )));
			
			CommandAttr(undef,"$uniqueDeviceName room $room");
			CommandAttr(undef,"$uniqueDeviceName webCmd :");
			#CommandAttr(undef,"$uniqueDeviceName webCmd Volume");
			CommandAttr(undef,"$uniqueDeviceName devStateIcon offline:control_home:on online:control_on_off:on standby:control_standby\@red:on standby-keep:control_standby\@red:on on:control_standby\@gray:off set-online:refresh");			
			CommandAttr(undef,"$uniqueDeviceName verbose ".AttrVal($name, "verbose", 3));
	
			Log3 $name, 1, $name.": Created device $uniqueDeviceName for ".$device->friendlyName();
	
			#update list
			@allTVs = PhilipsTV_getAllTVs($hash);
		}
		else{
			Log3 $hash, 3, $name.": Create device '".$device->modelName()."' with " .$device->UDN()." failed, because it isn't in filter!";
		}  	
	}
  
  	foreach my $TVHash (@allTVs) {
    	if($TVHash->{IP} eq PhilipsTV_checkIP($device->location())){
      		#device found, update data
      		$TVHash->{helper}{upnp}{device} = $device;
      		
      		#update device information
      		#$TVHash->{MAC} = uc(join( ':', substr($device->UDN(),29,12) =~ m/(\w{2})/g ));    # kommt eigentlich aus DEF
      		#$TVHash->{IP} = PhilipsTV_checkIP($device->location());                           # kommt eigentlich aus DEF
      		$TVHash->{UDN} = $device->UDN();
      		$TVHash->{upnp_friendlyName} = $device->friendlyName();
      		$TVHash->{upnp_modelName} = $device->modelName();
      		$TVHash->{upnp_location} = $device->location();
      		$TVHash->{upnp_deviceType} = $device->deviceType();
      		
      		if(AttrVal($TVHash->{NAME}, "expert", 0)){
      		    $TVHash->{upnp_manufacturer} = $device->manufacturer() ;
      		    $TVHash->{upnp_manufacturerURL} = $device->manufacturerURL() ;
      		    $TVHash->{upnp_modelDescription} = $device->modelDescription() ;
      		    $TVHash->{upnp_modelNumber} = $device->modelNumber() ;
      		    $TVHash->{upnp_modelURL} = $device->modelURL() ;
      		    $TVHash->{upnp_serialNumber} = $device->serialNumber() ;
      		    $TVHash->{upnp_presentationURL} = $device->presentationURL() ;
      		    $TVHash->{upnp_UPC} = $device->UPC() ;
      		}      		
      		
#       	deviceType friendlyName manufacturer manufacturerURL modelDescription modelName modelNumber modelURL serialNumber UDN presentationURL UPC location
#
# 		    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:3</deviceType>
# 		    <friendlyName>65OLED805/12</friendlyName>
# 		    <manufacturer>Philips</manufacturer>
# 		    <manufacturerURL>http://www.philips.com</manufacturerURL>
# 		    <modelDescription>UPnP Media Renderer 1.0</modelDescription>
# 		    <modelName>Philips TV DMR</modelName>
# 		    <modelNumber>2k15MTK</modelNumber>
# 		    <modelURL>http://www.philips.com/</modelURL>
# 		    <serialNumber>12345</serialNumber>
# 		    <UDN>uuid:F00DBABE-AA5E-BABA-DADA-68070a21404b</UDN>
#           <UPC>123456789012</UPC>

     		RemoveInternalTimer($TVHash, 'PhilipsTV_renewSubscriptions');
			
			#callbacks für services
			if(PhilipsTV_GetService($TVHash, "AVTransport")) {
        		$TVHash->{helper}{upnp}{AVTransport} = PhilipsTV_GetService($TVHash, "AVTransport")->subscribe(sub { PhilipsTV_subscriptionCallback($TVHash, @_); });
    			$TVHash->{sid_AVTransport} = $TVHash->{helper}{upnp}{AVTransport}->SID if(AttrVal($TVHash->{NAME}, "expert", 0));
    			Log3 $hash, 4, $name.": <addedDevice> initial subscription service AVTransport for ".$TVHash->{NAME};  
      		}
			if(PhilipsTV_GetService($TVHash, "ConnectionManager")) {
        		$TVHash->{helper}{upnp}{ConnectionManager} = PhilipsTV_GetService($TVHash, "ConnectionManager")->subscribe(sub { PhilipsTV_subscriptionCallback($TVHash, @_); });
    			$TVHash->{sid_ConnectionManager} = $TVHash->{helper}{upnp}{ConnectionManager}->SID if(AttrVal($TVHash->{NAME}, "expert", 0));
    			Log3 $hash, 4, $name.": <addedDevice> initial subscription service ConnectionManager for ".$TVHash->{NAME};  
      		}
			if(PhilipsTV_GetService($TVHash, "RenderingControl")) {
        		$TVHash->{helper}{upnp}{RenderingControl} = PhilipsTV_GetService($TVHash, "RenderingControl")->subscribe(sub { PhilipsTV_subscriptionCallback($TVHash, @_); });
    			$TVHash->{sid_RenderingControl} = $TVHash->{helper}{upnp}{RenderingControl}->SID if(AttrVal($TVHash->{NAME}, "expert", 0));
    			Log3 $hash, 4, $name.": <addedDevice> initial subscription service RenderingControl for ".$TVHash->{NAME};  
      		}
      		
      		# renewSubscriptions starten
			$TVHash->{helper}{upnp}{keepalive} = AttrVal($TVHash->{NAME}, "renewSubscription", 200); 
      		 
      		# BlockingKill RUNNING_PID exist - delete
      		if(exists($TVHash->{helper}{upnp}{RUNNING_PID})){
      			BlockingKill($TVHash->{helper}{upnp}{RUNNING_PID});
      			delete($TVHash->{helper}{upnp}{RUNNING_PID});
      		}
			InternalTimer(gettimeofday() + $TVHash->{helper}{upnp}{keepalive}, 'PhilipsTV_renewSubscriptions', $TVHash, 0);

			Log3 $hash, 3, $TVHash->{NAME}.": current status during the Upnp search response - ".$TVHash->{STATE};
			
            $TVHash->{helper}{upnp}{STATE} = FIRSTFOUND; 					# für GetStatus
            $TVHash->{helper}{upnp}{timestamp}{found} = gettimeofday(); 	# für GetStatus Log
            InternalTimer(gettimeofday()+2, "PhilipsTV_GetStatus", $TVHash);			#Statusabfrage übernimmt
            InternalTimer(gettimeofday()+2, "PhilipsTV_VolumeUpnpRequest", $TVHash);	#1x die Audiowerte holen als Init
            
 			#wenn TV verbunden ist, aber eine neue Search gestartet wird, soll kein Statuswechsel erfolgen
       	    readingsSingleUpdate($TVHash,"state","online",1) if($TVHash->{STATE} eq "offline");
        	Log3 $hash, 3, $TVHash->{NAME}.": state of UPnP - online";
  		}
  	}
  
  	return undef;
}

sub PhilipsTV_removedDevice {
  	my ($hash, $device) = @_;
  	my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <removedDevice> called ";  	
  
  	my $TVHash = PhilipsTV_getHashByIP($hash, PhilipsTV_checkIP($device->location()));
  	
  	return undef if(!defined($TVHash));
	
	RemoveInternalTimer($TVHash, 'PhilipsTV_renewSubscriptions');
	if(exists($TVHash->{helper}{upnp}{RUNNING_PID})){
		BlockingKill($TVHash->{helper}{upnp}{RUNNING_PID});
		delete($TVHash->{helper}{upnp}{RUNNING_PID});
	}

	delete($TVHash->{helper}{upnp}{device});
	$TVHash->{helper}{upnp}{STATE} = REMOVED; 						# für GetStatus
	$TVHash->{helper}{upnp}{timestamp}{removed} = gettimeofday(); 	# für GetStatus Log
	
	# wenn kein Polling, dann dies doch starten um offline zu erkennen
	RemoveInternalTimer($TVHash, "PhilipsTV_GetStatus");
	InternalTimer(gettimeofday()+2, "PhilipsTV_GetStatus", $TVHash);

	Log3 $hash, 3, $TVHash->{NAME}.": state of UPnP - offline";
	return undef;
}

sub PhilipsTV_renewSubscriptions {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	
  	Log3 $hash, 4, $name.": <renewSubscription> try to renew subscriptions for services ";

  	if(!exists($hash->{helper}{upnp}{RUNNING_PID})){
  		InternalTimer(gettimeofday() + $hash->{helper}{upnp}{keepalive}, 'PhilipsTV_renewSubscriptions', $hash, 0);
  		$hash->{helper}{upnp}{RUNNING_PID} = BlockingCall('PhilipsTV_renewSubscriptionBlocking', $hash->{NAME}, 'PhilipsTV_renewSubscriptionBlockingDone', 10, 'PhilipsTV_renewSubscriptionBlockingAborted', $hash) ;
  		Log3 $hash, 4, $name.": <renewSubscription> try to renew subscriptions for services with repeat in ".$hash->{helper}{upnp}{keepalive}."s";
  	}
  	else{
   		Log3 $hash, 1, $name.": <renewSubscription> failed to call renewSubscriptionBlocking, check Log";
		
		RemoveInternalTimer($hash, "PhilipsTV_renewSubscriptions");
		Log3 $name, 3, $name.": state of blocking - offline";

		# Status auf offline
		RemoveInternalTimer($hash, "PhilipsTV_GetStatus");
		$hash->{helper}{upnp}{STATE} = REMOVED; 
		readingsSingleUpdate($hash,"state","offline",1);
		readingsSingleUpdate($hash,"data","notready",1);

		# UPnP neu starten
		my $hashAccount = PhilipsTV_getHashOfAccount($hash);
		InternalTimer(gettimeofday() + 20, "PhilipsTV_rescanNetwork", $hashAccount) ;
		
		Log3 $hash, 3, $name.': <renewSubscription> rescan network will be start in 20s';
		
  	}
 
  	return undef;
}

sub PhilipsTV_renewSubscriptionBlocking {
  	my ($string) = @_;
  	my ($name) = split("\\|", $string);
  	my $hash = $main::defs{$name};
  	my $err;
  	my $timeout = 0;
  	my $expired = 0;

#   	local $SIG{__WARN__} = sub {
#     	my ($called_from) = caller(0);
#     	my $wrn_text = shift;
#     	$wrn_text =~ m/^(.*?)\sat\s.*?$/;
#     	Log3 $name, 1, $name.": <renewSubscriptionBlocking> renewal of subscription failed: $1";
#     	#Log3 $name, 1, $name.": <renewSubscriptionBlocking> renewal of subscription failed: ".$called_from.", ".$wrn_text;
#   	};

  	Log3 $name, 4, $name.": <renewSubscriptionBlocking> try to renew subscriptions for services";  
 
  	# register callbacks again
  	eval {
  		local $SIG{__WARN__} = sub { die $_[0] };
  		
    	if(defined($hash->{helper}{upnp}{AVTransport})) {
      		$hash->{helper}{upnp}{AVTransport}->renew();
      		$timeout = $hash->{helper}{upnp}{AVTransport}->timeout();
      		$expired = $hash->{helper}{upnp}{AVTransport}->expired();
    	}
  	};
 	if($@) {
  		$err = $@;
  		$err =~ m/^(.*?)\sat\s(.*?)$/;
    	Log3 $name, 2, $name.": <renewSubscriptionBlocking> renewal of subscription service AVTransport failed: $1 ";
    	Log3 $name, 5, $name.": <renewSubscriptionBlocking> renewal of subscription service AVTransport failed at: $2";
    	return "$name|$1|undef|undef";
  	}

   	eval {
   		local $SIG{__WARN__} = sub { die $_[0] };
   		
    	if(defined($hash->{helper}{upnp}{ConnectionManager})) {
      		$hash->{helper}{upnp}{ConnectionManager}->renew();
      		$timeout = $hash->{helper}{upnp}{ConnectionManager}->timeout();
      		$expired = $hash->{helper}{upnp}{ConnectionManager}->expired();
    	}
  	};
 	if($@) {
  		$err = $@;
  		$err =~ m/^(.*?)\sat\s(.*?)$/;
    	Log3 $name, 2, $name.": <renewSubscriptionBlocking> renewal of subscription service ConnectionManager failed: $1 ";
    	Log3 $name, 5, $name.": <renewSubscriptionBlocking> renewal of subscription service ConnectionManager failed at: $2";
    	return "$name|$1|undef|undef";
  	}

  	eval {
  		local $SIG{__WARN__} = sub { die $_[0] };
  		
    	if(defined($hash->{helper}{upnp}{RenderingControl})) {
      		$hash->{helper}{upnp}{RenderingControl}->renew();
      		$timeout = $hash->{helper}{upnp}{RenderingControl}->timeout();
      		$expired = $hash->{helper}{upnp}{RenderingControl}->expired();
    	}
  	};
 	if($@) {
  		$err = $@;
  		$err =~ m/^(.*?)\sat\s(.*?)$/;
    	Log3 $name, 2, $name.": <renewSubscriptionBlocking> renewal of subscription service RenderingControl failed: $1 ";
    	Log3 $name, 5, $name.": <renewSubscriptionBlocking> renewal of subscription service RenderingControl failed at: $2";
    	return "$name|$1|undef|undef";
  	}

  	Log3 $name, 4, $name.": <renewSubscriptionBlocking> finished to renew subscriptions for services ";  

  	return "$name|0|$timeout|$expired";
}

sub PhilipsTV_renewSubscriptionBlockingAborted {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	Log3 $hash, 1, $name.': <renewSubscriptionBlockingAborted> subscription for services is aborted - possible reason for timeout: "No route to host"';
	
	delete($hash->{helper}{upnp}{RUNNING_PID});
	
	RemoveInternalTimer($hash, "PhilipsTV_renewSubscriptions");
	Log3 $name, 3, $name.": state of network - offline";
	
	# Status auf offline
	RemoveInternalTimer($hash, "PhilipsTV_GetStatus");
	$hash->{helper}{upnp}{STATE} = REMOVED; 
	readingsSingleUpdate($hash,"state","offline",1);
	readingsSingleUpdate($hash,"data","notready",1);

	# UPnP neu starten
	my $hashAccount = PhilipsTV_getHashOfAccount($hash);
	InternalTimer(gettimeofday() + 20, "PhilipsTV_rescanNetwork", $hashAccount) ;

	Log3 $hash, 3, $name.': <renewSubscriptionBlockingAborted> rescan network will be start in 20s';
	
	return undef;
}

sub PhilipsTV_renewSubscriptionBlockingDone {
	my ($string) = @_;

  	my ($name, $err, $timeout, $expired) = split("\\|", $string);
  	my $hash = $main::defs{$name};
	
	delete($hash->{helper}{upnp}{RUNNING_PID});
	
	Log3 $name, 4, $name.": <renewSubscriptionBlockingDone> Error: ".$err." Timeout: ".$timeout." Expired: ".$expired;
  	
	if($err ne "0"){

		Log3 $hash, 1, $name.": <renewSubscriptionBlockingDone> renewal of subscription failed: ".$err;
		
		RemoveInternalTimer($hash, "PhilipsTV_renewSubscriptions");
		Log3 $name, 3, $name.": state of network - offline";

		# Status auf offline
		RemoveInternalTimer($hash, "PhilipsTV_GetStatus");
		$hash->{helper}{upnp}{STATE} = REMOVED; 
		readingsSingleUpdate($hash,"state","offline",1);
		readingsSingleUpdate($hash,"data","notready",1);
	
		if($err =~ m/ 412 /){
			# UPnP neu starten
			# 412 Precondition Failed detected -> Rescan Network?
			my $hashAccount = PhilipsTV_getHashOfAccount($hash);
			InternalTimer(gettimeofday() + 20, "PhilipsTV_rescanNetwork", $hashAccount) ;
		
			Log3 $hash, 3, $name.': <renewSubscriptionBlockingDone> rescan network will be start in 20s';
			
			return undef;
		}
		elsif($err =~ m/ 500 /){
			# UPnP Search neu starten
			# 500 Can't connect to host (Connection refused)
			my $hashAccount = PhilipsTV_getHashOfAccount($hash);
			InternalTimer(gettimeofday() + 20, "PhilipsTV_startSearch", $hashAccount) ;
		
			Log3 $hash, 3, $name.': <renewSubscriptionBlockingDone> Upnp search will be start in 20s';
			
			return undef;
		}

# 		# UPnP Search neu starten
# 		my $hashAccount = PhilipsTV_getHashOfAccount($hash);
# 		InternalTimer(gettimeofday() + 20, "PhilipsTV_startSearch", $hashAccount) ;
# 	
# 		Log3 $hash, 3, $name.': <renewSubscriptionBlockingDone> Upnp search will be start in 20s';
		
		return undef;
	}	

	$hash->{helper}{upnp}{keepalive} = $timeout - 10 if($timeout =~ /^\d+$/);

  	Log3 $hash, 4, $name.": <renewSubscriptionBlockingDone> finished to renew subscriptions for services with repeat in ".$hash->{helper}{upnp}{keepalive}."s";

	return undef;
}

# Sockets ######################################################################

sub PhilipsTV_newChash {
  my ($hash,$socket,$chash) = @_;

  $chash->{TYPE}  = $hash->{TYPE};
  $chash->{SUBTYPE}  = "UPnPSocket";
  $chash->{STATE}   = "open"; 

  $chash->{NR}    = $devcount++;

  $chash->{phash} = $hash;
  $chash->{PNAME} = $hash->{NAME};

  $chash->{CD}    = $socket;
  $chash->{FD}    = $socket->fileno();

  $chash->{PORT}  = $socket->sockport if( $socket->sockport );

  $chash->{TEMPORARY} = 1;
  $attr{$chash->{NAME}}{room} = 'hidden';

  $defs{$chash->{NAME}}       = $chash;
  $selectlist{$chash->{NAME}} = $chash;
}

sub PhilipsTV_addSocketsToMainloop {
  my ($hash) = @_;
  my $name ;
  my @sockets = $hash->{helper}{upnp}{controlpoint}->sockets();
  
  #check if new sockets need to be added to mainloop
  foreach my $s (@sockets) {
    #create chash and add to selectlist
    if( $s->sockport ) {
    	$name  = "UPnPSocket_".$hash->{NAME}."_".$s->sockport;
    }
    else {
    	$name  = "UPnPSocket_".$hash->{NAME};
    }
    
    Log3 $name, 5, $name.": <addSocketsToMainloop> add ".$s;
    
  	my $chash = PhilipsTV_newChash($hash, $s, {NAME => $name});
  }
  
  return undef;
}

# Call Services ################################################################

sub PhilipsTV_VolumeUpnpRequest {
    my ( $hash ) = @_;
    my $name = $hash->{NAME};
	
	# nur wenn per Upnp gefunden 
	if($hash->{helper}{upnp}{STATE} == FOUND){
		unless(PhilipsTV_GetAllowedTransforms($hash)){
            Log3 $name, 3, $name.": audio - allowed transforms request unsuccessful!";
        } 
		unless(PhilipsTV_GetMute($hash)){
            Log3 $name, 3, $name.": audio - mute request unsuccessful!";
        } 
		unless(PhilipsTV_GetVolume($hash)){
            Log3 $name, 3, $name.": audio - volume request unsuccessful!";
        } 
	}
	return undef;
}

sub PhilipsTV_SetVolume {
  my ($hash, $volume) = @_;
  return PhilipsTV_CallRenderingControl($hash, "SetVolume", 0, "Master", $volume);
}

sub PhilipsTV_GetVolume {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	
  	Log3 $name, 5, $name.": <GetVolume> called ";
  	
	my $getVolumeHash = PhilipsTV_CallRenderingControl($hash, "GetVolume", 0, "Master");
		
	if(defined($getVolumeHash)){
		my $volume = $getVolumeHash->getValue("CurrentVolume");
		$hash->{helper}{volume}{Master}{current} = $volume;
		readingsSingleUpdate($hash,"Volume",$volume,1);		
		return 1;
  	}
  	return undef;
}

sub PhilipsTV_SetMute {
  my ($hash, $mute) = @_;
  return PhilipsTV_CallRenderingControl($hash, "SetMute", 0, "Master", $mute);
}

sub PhilipsTV_GetMute {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	
  	Log3 $name, 5, $name.": <GetMute> called ";
  	
	my $getMuteHash = PhilipsTV_CallRenderingControl($hash, "GetMute", 0, "Master");
		
	if(defined($getMuteHash)){
		my $mute = $getMuteHash->getValue("CurrentMute");
		$hash->{helper}{volume}{Master}{mute} = $mute;
		readingsSingleUpdate($hash,"Mute",$mute,1);		
		return 1;
  	}
  	return undef;
}

sub PhilipsTV_GetAllowedTransforms {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	
  	Log3 $name, 5, $name.": <GetAllowedTransforms> called ";
  	
	my $getTransformsHash = PhilipsTV_CallRenderingControl($hash, "GetAllowedTransforms", 0);
		
	if(defined($getTransformsHash)){
		$hash->{helper}{volume}{Master}{allowedTransforms} = $getTransformsHash->getValue("CurrentAllowedTransformSettings");
  
#       Debug($hash->{helper}{volume}{Master}{allowedTransforms});
       
#       <?xml version="1.0" encoding="UTF-8"?>
# 			<TransformList xmlns="urn:schemas-upnp-org:av:AllowedTransformSettings" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:schemas-upnp-org:av:AllowedTransformSettings http://www.upnp.org/schemas/av/AllowedTransformSettings.xsd">
# 				<transform name="Volume_Master" shared="1">
# 					<friendlyName>Volume</friendlyName>
# 					<allowedValueRange inactiveValue="0" unit="1">
# 						<minimum>0</minimum>
# 						<maximum>100</maximum>
# 						<step>1</step>
# 					</allowedValueRange>
# 				</transform>
# 			</TransformList>
        
 		$hash->{helper}{volume}{Master}{allowedTransforms} =~ m/<transform.*?name=\"(.*?)\"/;
     	if($1 eq "Volume_Master"){
     		$hash->{helper}{volume}{Master}{allowedTransforms} =~ m/<minimum>(.*?)<\/minimum>/;
     		$hash->{helper}{volume}{Master}{minimum} = $1;
     		$hash->{helper}{volume}{Master}{allowedTransforms} =~ m/<maximum>(.*?)<\/maximum>/;
     		$hash->{helper}{volume}{Master}{maximum} = $1;
     		$hash->{helper}{volume}{Master}{allowedTransforms} =~ m/<step>(.*?)<\/step>/;
     		$hash->{helper}{volume}{Master}{step} = $1;
        	return 1;
     	}
  	}
  	return undef;
}


sub PhilipsTV_CallRenderingControl {
  my ($hash, $method, @args) = @_;
  return PhilipsTV_CallService($hash, "RenderingControl", $method, @args);
}

sub PhilipsTV_CallAVTransport {
  my ($hash, $method, @args) = @_;
  return PhilipsTV_CallService($hash, "AVTransport", $method, @args);
}

sub PhilipsTV_CallConnectionManager {
  my ($hash, $method, @args) = @_;
  return PhilipsTV_CallService($hash, "ConnectionManager", $method, @args);
}

sub PhilipsTV_CallService {
  	my ($hash, $service, $method, @args) = @_;
  	my $name = $hash->{NAME};
  
   	Log3 $name, 5, $name.": <GetService> called ";
  
  	my $upnpService = PhilipsTV_GetService($hash, $service);
  	my $result = undef;

	eval {
  		my $upnpServiceCtrlProxy = $upnpService->controlProxy();
  		my $methodExists = $upnpService->getAction($method);
  		if($methodExists) {
    		$result = $upnpServiceCtrlProxy->$method(@args);
    		Log3 $name, 5, $name.": <CallService> $service: $method(".join(",",@args).") succeed.";
  		} else {
    		Log3 $name, 4, $name.": <CallService> $service: $method(".join(",",@args).") does not exist.";
  		}
	};

	if($@) {
  		Log3 $name, 1, $name.": $service: $method(".join(",",@args).") failed, $@";
	}

	return $result;
}

# Get Service ##################################################################

sub PhilipsTV_GetService {
  	my ($hash, $service) = @_;
  	my $name = $hash->{NAME};
  
  	Log3 $name, 5, $name.": <GetService> called ";
  
  	my $upnpService;
  	#ToDo defined device?
  	if(!defined($hash->{helper}{upnp}{device})) {
    	Log3 $name, 1, $name.": $service unknown, device not defined";
    	return undef;
  	}  	
   	
  	foreach my $srvc ($hash->{helper}{upnp}{device}->services) {
    	my @srvcParts = split(":", $srvc->serviceType);
    	my $serviceName = $srvcParts[-2];
    	if($serviceName eq $service) {
      		Log3 $name, 5, $name.": <GetService> $service: ".$srvc->serviceType." found. OK.";
      		$upnpService = $srvc;
    	}
  	}
  
  	if(!defined($upnpService)) {
    	Log3 $name, 1, $name.": $service unknown";
    	return undef;
  	}
  
  	return $upnpService;
}

# Subscription Callback ########################################################
 
sub PhilipsTV_subscriptionCallback {
  	my ($hash, $service, %properties) = @_;
  	my $name = $hash->{NAME};
  	
 	Log3 $name, 5, $name.": <subscriptionCallback> serviceID ".$service->serviceType." received event";#.Dumper(%properties);
  	
 	while (my ($key, $val) = each %properties) {
    	$key = decode_entities($key);
    	$val = decode_entities($val);
    	
     	Log3 $name, 5, $name.": <subscriptionCallback> Property ${key}'s value is $val";

        #  Property LastChange's value is <Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/">
        # <InstanceID val="0">
        # <PresetNameList val="FactoryDefaults"/>
        # <Volume channel="Master" val="20"/>
        # <Mute channel="Master" val="0"/>
        # </InstanceID>
        # </Event>

#     my $xml;
#     eval {
#       if($properties{$property} =~ /xml/) {
#         $xml = XMLin($properties{$property}, KeepRoot => 1, ForceArray => [qw(Volume Mute Loudness VolumeDB group)], KeyAttr => []);
#       } else {
#         $xml = $properties{$property};
#       }
#     };
#     
#     if($@) {
#       Log3 $hash, 2, "DLNARenderer: XML formatting error: ".$@.", ".$properties{$property};
#       next;
#     }

    	
    	if(($key =~ /^LastChange/) && ($service->serviceType eq "urn:schemas-upnp-org:service:RenderingControl:3")){
    		readingsBeginUpdate($hash); 	
     		    $val =~ m/<Volume.*?val=\"(.*?)\"\/>/;
     		    $hash->{helper}{volume}{Master}{current} = $1;
    		    readingsBulkUpdate($hash, "Volume", $1);
    		    $val =~ m/<Mute.*?val=\"(.*?)\"\/>/;
    		    $hash->{helper}{volume}{Master}{mute} = $1;
    		    readingsBulkUpdate($hash, "Mute", $1);
            readingsEndUpdate($hash, 1);
    	}
    }
  	return undef;
}

# Find Hash's ##################################################################

sub PhilipsTV_getAllTVs {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	
    Log3 $name, 5, $name.": <getAllTVs> called ";  	
  	
  	my @Devices = ();
    
  	foreach my $fhem_dev (sort keys %main::defs) {
    	push @Devices, $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'PhilipsTV' && $main::defs{$fhem_dev}{SUBTYPE} eq 'TV');
  	}
		
  	return @Devices;
}

sub PhilipsTV_getAllUPnPSockets {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
  	
    Log3 $name, 5, $name.": <getAllUPnPSockets> called ";  	
  	
  	my @Devices = ();
    
  	foreach my $fhem_dev (sort keys %main::defs) {
    	push @Devices, $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'PhilipsTV' && $main::defs{$fhem_dev}{SUBTYPE} eq 'UPnPSocket');
  	}
		
  	return @Devices;
}

sub PhilipsTV_getHashByUDN {
  	my ($hash, $udn) = @_;
  	my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <getHashByUDN> called ";  	
  	
  	foreach my $fhem_dev (sort keys %main::defs) {
    	return $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'PhilipsTV' && $main::defs{$fhem_dev}{SUBTYPE} ne 'PHILIPS' && $main::defs{$fhem_dev}{SUBTYPE} ne 'UPnPSocket' && $main::defs{$fhem_dev}{UDN} eq $udn);
  	}
		
  	return undef;
}

sub PhilipsTV_getHashByIP {
  	my ($hash, $ip) = @_;
  	my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <getHashByIP> called ";  	
  	
  	foreach my $fhem_dev (sort keys %main::defs) {
    	return $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'PhilipsTV' && $main::defs{$fhem_dev}{SUBTYPE} ne 'PHILIPS' && $main::defs{$fhem_dev}{SUBTYPE} ne 'UPnPSocket' && $main::defs{$fhem_dev}{IP} eq $ip);
  	}
		
  	return undef;
}


sub PhilipsTV_getHashOfAccount {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};

    Log3 $name, 5, $name.": <getHashOfAccount> called ";  	
  	
  	foreach my $fhem_dev (sort keys %main::defs) {
    	return $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'PhilipsTV' && $main::defs{$fhem_dev}{SUBTYPE} eq 'PHILIPS');# && $main::defs{$fhem_dev}{UDN} eq "0" && $main::defs{$fhem_dev}{UDN} ne "-1"));
  	}
		
  	return undef;
}

# rescan Network ###############################################################

sub PhilipsTV_rescanNetwork {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
 
 	Log3 $name, 5, $name.": <rescanNetwork> called";
 
	PhilipsTV_StopControlPoint($hash);
	if(PhilipsTV_setupControlpoint($hash)){
		PhilipsTV_startSearch($hash);
	}  	
    
  	#RescanNetwork nach x min wieder starten, wenn gewollt
  	if(AttrVal($name,"rescanNetworkInterval",0) > 0){
  		Log3 $name, 5, $name.": <rescanNetwork> succesfull setup of rescan network - interval";
  		readingsSingleUpdate($hash,"state","Upnp is running - interval",1);
  		InternalTimer(gettimeofday() + (AttrVal($name,"rescanNetworkInterval",1) * 60), "PhilipsTV_rescanNetwork", $hash);
	}
  	else{
  		Log3 $name, 5, $name.": <rescanNetwork> succesfull setup of rescan network";
  		readingsSingleUpdate($hash,"state","Upnp is running",1);
	}  	
 	
  	return undef;
}

# check IP #####################################################################

sub PhilipsTV_checkIP {
  	my ($ip) = @_;
  
    if($ip =~ /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/){
        $ip = $1;
    }
    chomp($ip);
  
    if($ip =~ m/^(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)$/){
        if($1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255){
            return "$1.$2.$3.$4";
        }
    }
    return undef;
}

# check MAC ####################################################################

sub PhilipsTV_checkMAC {
  	my ($mac) = @_;
  	
  	#Debug("-".$mac."-"); #68:07:0A:21:40:4B
  
    if($mac =~ /^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})|([0-9a-fA-F]{4}\\.[0-9a-fA-F]{4}\\.[0-9a-fA-F]{4})$/ ){
        return 1;
    }

    return undef;
}

# refresh screen ###############################################################

sub PhilipsTV_RefreshScreen {
  	my ($hash) = @_;
  	my $name = $hash->{NAME};
 
 	Log3 $name, 5, $name.": <RefreshScreen> called";
 	
 	my $room = AttrVal($name, 'room', 'Unsorted');

	FW_directNotify("FILTER=(room=$room|$name)", "#FHEMWEB:$FW_wname", "location.reload()", "") if defined($FW_wname);
	
	return undef;
} 

# find Menuitem ################################################################

sub PhilipsTV_menuitemsSearch {
    my ($ref, $search) = @_;
    my $result;
    
    if (ref($ref) eq 'HASH') {
        for my $key (keys %$ref) {
            $result = PhilipsTV_menuitemsSearch($ref->{$key}, $search);
            return $result if(ref($result) eq 'HASH');
        }
    }
    elsif (ref($ref) eq 'ARRAY') {
        for my $item (@$ref) {
            # suche 'string_id'
            if(ref($item) eq 'HASH'){
                if(exists($item->{string_id})){
                    if($item->{string_id} eq $search){
                        return $item;
                    }
                }
            }
            # noch nicht gefunden
            $result = PhilipsTV_menuitemsSearch($item, $search);
            return $result if(ref($result) eq 'HASH');
        }
    }
    return undef;
}

# Convert Bool #################################################################

sub PhilipsTV_convertBool {

    local *_convert_bools = sub {
        my $ref_type = ref($_[0]);
        if ($ref_type eq 'HASH') {
            _convert_bools($_) for values(%{ $_[0] });
        }
        elsif ($ref_type eq 'ARRAY') {
            _convert_bools($_) for @{ $_[0] };
        }
        elsif (
               $ref_type eq 'JSON::PP::Boolean'           # JSON::PP
            || $ref_type eq 'Types::Serialiser::Boolean'  # JSON::XS
        ) {
            $_[0] = $_[0] ? 1 : 0;
        }
        else {
            # Nothing.
        }
    };

    &_convert_bools;

}

################################################################################

# Eval-Rückgabewert für erfolgreiches
# Laden des Moduls
1;


# Beginn der Commandref ########################################################

=pod

=encoding utf8

=item device
=item summary Controlling of Philips TV's
=item summary_DE Steuerung von Philips TV's

=begin html

<a name="PhilipsTV" id="PhilipsTV"></a>
<h3>
	PhilipsTV
</h3>
<ul>
  	PhilipsTV finds Philips TV's automatically, controls them and displays various information.<br />
  	<br />
  	<a name="PhilipsTV_Define" id="PhilipsTV_Define"></a><b>Define</b>
  	<ul>
    	<code>define &lt;name&gt; PhilipsTV</code><br />
    	<br />
    	Example: <code>define Philips PhilipsTV</code><br />
  	</ul><br />
  	<b>Note</b>
  	<ul>
    	Please see the german help for more information, many thanks.<br />
  	</ul><br />  
</ul>

=end html

=begin html_DE

<a name="PhilipsTV" id="PhilipsTV"></a>
<h3>
	PhilipsTV
</h3>
<ul>
  	PhilipsTV findet automatisch Philips TV's, kann diese steuern und zeigt weitere Informationen an.<br />
  	<br />
    <b>Hinweis:</b> Folgende Libraries sind notwendig für dieses Modul:
	<ul>
		<li>JSON</li>
		<li>Digest::MD5</li>
		<li>MIME::Base64</li>
		<li>HTML::Entities</li>
		<li>Data::Dumper</li>
		<li>LWP::UserAgent</li>
		<li>LWP::Protocol::https/li>
		<li>HTTP::Request</li>
		<br />
	</ul>
  	<a name="PhilipsTV_Define" id="PhilipsTV_Define"></a><b>Define</b>
  	<ul>
    	<code>define &lt;name&gt; PhilipsTV</code><br />
    	<br />
    	Example: <code>define Philips PhilipsTV</code><br />
    	<br />
    	Nach ca. 2 Minuten sollten alle TV's gefunden und unter "PhilipsTV" gelistet sein.
  	</ul><br />
  	<a name="PhilipsTV_Set" id="PhilipsTV_Set"></a><b>Set</b>
	<ul>
	    PHILIPS<br />
		<ul>
			<li><b>RescanNetwork</b><br />
	  			Startet die Suche nach Philips TV's erneut. Beendet dabei bestehende Verbindungen und baut diese erneut auf.
			</li>
			<li><b>StartUpnpSearch</b><br />
				Startet die Upnp Suche nach Geräten nochmals. Startet den ControlPoint aber nicht neu.
			</li>
		</ul>
	</ul><br />
  	<ul>
	    TV<br />
	    <ul>
			<li><b>wenn TV offline ist</b><br />
				<ul>
					<li><b>on</b><br />
			  			Schaltet den Philips TV ein.
					</li>
					<li><b>off</b><br />
			  			Schaltet den Philips TV aus.
					</li>
					<li><b>toggel</b><br />
			  			Schaltet den Philips TV aus oder ein, je nach vorherigem Status.
					</li>
			    </ul><br />
		    </li>
			<li><b>wenn TV nicht gepairt ist oder das Pairing läuft</b><br />
				<ul>
					<li><b>PairRequest</b><br />
			  			Startet das Pairing. Auf dem TV sollte jetzt ein Pincode erscheinen.
					</li>
					<li><b>Pin</b><br />
			  			Eingabe des Pincodes.
					</li>
			    </ul><br />
		    </li>
			<li><b>wenn Pairing erfolgreich war</b><br />
				<ul>
					<li><b>Ambilight</b><br />
			  			Setzt einen Remotebefehl ab. Entspricht den Befehlen der Fernbedienung.
					</li>
					<li><b>Application</b><br />
			  			Startet die ausgewählte Application.
					</li>
					<li><b>Channel</b><br />
			  			Schaltet den Sender nach Sendernummer um.
					</li>
					<li><b>ChannelName</b><br />
			  			Schaltet den Sender nach Sendernamen um.
					</li>
					<li><b>HDMI</b><br />
			  			Auswahl des HDMI Einganges.<br />
			  			Der Befehl wird über Google-Assistant abgesetzt.
					</li>
					<li><b>MenuItem</b><br />
			  			Setzt einen Wert für eine Manüauswahl.<br />
			  			Beispiele:<br />
			  			<ul>
				  			<code>set ManueItem AUDIO_OUT_DELAY 2</code> - setzt den Bypass für Audioausgang, ist hilfreich um die Lippensynchronität bei HDMI hinzubekommen.<br /> 
			    			<code>set ManueItem SWITCH_ON_WITH_WIFI_WOWLAN 1</code> - mit WiFi (WoWLAN) einschalten.<br />
			    			<code>set ManueItem SWITCH_ON_WITH_CHROMECAST 1</code> - Einschalten mit Chromecast.<br />
						</ul>
						Über expert = 1 und <code>get MenuStructure</code> läßt sich die Menü Struktur erkunden. Aus dem Key <code>'string_id' => 'org.droidtv.ui.strings.R.string.MAIN_AUDIO_OUT_DELAY'</code> nur ab <code>...MAIN_</code> die Zeichenkette nehmen. Über <code>get MenuItem AUDIO_OUT_DELAY</code> (<code>AUDIO_OUT_DELAY</code> als Beispiel) läßt sich ermitteln, welchen Zustand eine Einstellung hat und welche Werte akzeptiert werden würden. Fragt gern bei mir nach.
					</li>
					<li><b>PairRequest</b><br />
			  			Startet das Pairing. Auf dem TV sollte jetzt ein Pincode erscheinen.<br />
			  			Anschließend den Pincode in mit <code>set Pin xxxx</code> eingeben.
					</li>
					<li><b>Remote</b><br />
			  			Setzt einen Remotebefehl ab. Entspricht den Befehlen der Fernbedienung.
					</li>
					<li><b>Volume</b><br />
			  			Lautstärke.<br />
			  			Hinweis: Wert wird über Upnp gesendet. In Zusammenhang mit angeschlossenen Audiosystemen, scheinen ein paar nicht ganz erklärbare Effekte zu entstehen.
					</li>
			    </ul><br />
		    </li>
		</ul>
	</ul><br />  
  	<a name="PhilipsTV_Get" id="PhilipsTV_Get"></a><b>Get</b>
  	<ul>
    	PHILIPS<br />
    	<ul>
			<li><b>NOP</b><br />
				Nichts definiert.
			</li>
    	</ul>
   	</ul><br />
  	<ul>
    	TV<br />
    	<ul>
			<li><b>AmbihueStatus</b><br />
				Gibt den Status des Ambihue zurück.
			</li>
			<li><b>Powerstate</b><br />
				Gibt den aktuellen Zustand vom TV zurück.
			</li>
			<li><b>VolumeEndpoint</b><br />
				Gibt den aktuellen Lautstärke zurück über Http Request.
			</li>
			<li><b>VolumeUpnp</b><br />
				Gibt den aktuellen Lautstärke zurück über Upnp Request.<br />
				Verhält sich manchmal nicht so wie man denkt, vor allem wenn noch ein Audio System angeschlossen ist.
			</li>
			<li><b>wenn expert = 1 ist</b><br />
				<ul>
					<li><b>Applications</b><br />
						Gibt die Applications als Hashstruktur zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>ChannelDb</b><br />
						Gibt die ChannelDb (Grundstruktur für ChannelList) als Hashstruktur zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>ChannelList</b><br />
						Gibt die Channellist als Hashstruktur zurück. Inklusive aller Favoritenlisten. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>CurrentApp</b><br />
						Gibt den Inhalt der Abfrage der aktuellen Application als Hashstruktur zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.<br />
						Verwendung noch unklar.
					</li>
					<li><b>CurrentChannel</b><br />
						Gibt den Inhalt der Abfrage des aktuellen Senders als Hashstruktur zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>FavoriteList</b><br />
						Gibt den Inhalt einer Favoritenliste als Hashstruktur zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>Input</b><br />
						Experimentell - soll wohl bei älteren Geräten mal funktioniert haben. Wenn ja, bitte mal eine Rückmeldung.
					</li>
					<li><b>MacAddress</b><br />
						Gibt die akuell eingestellte MAC Adresse zurück.
					</li>
					<li><b>MenuItem</b><br />
						Gibt den Status eines bestimten Menupunktes zurück.<br />
						ToDo: Liste noch ergänzen 
					</li>
					<li><b>MenuStructure</b><br />
						Gibt Menü Struktur des TV's zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>NetworkInfo</b><br />
						Gibt aktuelle Netzwerkinfos des TV's zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>NotifyChanges</b><br />
						Gibt aktuelle Daten zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>SystemRequest</b><br />
						Gibt systemrelevante Daten zurück. Wenn TV offline ist, werden gespeicherte Daten zurückgegeben.
					</li>
					<li><b>isOnline</b><br />
						Gibt an, ob der TV in Netzwerk erreichbar ist (Ping).
					</li>
			    </ul><br />
		    </li>
    	</ul>
   	</ul><br />  	
   	<a name="PhilipsTV_Attr" id="PhilipsTV_Attr"></a><b>Attributes</b>
  	<ul>
  		PHILIPS<br />
  		<ul>
			<li><b>acceptedModelName</b><br />
				Default 'Philips TV DMR'<br />
				Filter für Modelnamen der per Upnp gefunden werden soll.
			</li>
			<li><b>acceptedUDNs</b><br />
				Eine Liste (durch Kommas oder Leerzeichen getrennt) von UDNs, die von der automatischen Geräteerstellung akzeptiert werden soll.<br />
				Es ist wichtig, dass uuid: ebenfalls Teil der UDN ist und enthalten sein muss.
			</li>
			<li><b>ignoreUDNs</b><br />
				Eine Liste (durch Kommas oder Leerzeichen getrennt) von UDNs, die von der automatischen Geräteerstellung ausgeschlossen werden soll.<br />
				Es ist wichtig, dass uuid: ebenfalls Teil der UDN ist und enthalten sein muss.
			</li>
			<li><b>ignoredIPs</b><br />
				Eine Liste (durch Kommas oder Leerzeichen getrennt) von IPs die ignoriert werden sollen.
			</li>
			<li><b>usedonlyIPs</b><br />
				Eine Liste (durch Kommas oder Leerzeichen getrennt) von IPs die für die Suche genutzt werden sollen.
			</li>
			<li><b>subscritionPort</b><br />
				Default ist ein zufälliger freier Port<br />
				Subscrition Port für die UPnP Services, welche der Controlpoint anlegt. 
			</li>
			<li><b>searchPort</b><br />
				Default 8008<br />
				Search Port für die UPnP Services, welche der Controlpoint anlegt.
			</li>
			<li><b>reusePort</b><br />
				Default 0<br />
				Gibt an, ob die Portwiederwendung für SSDP aktiviert werden soll, oder nicht. Kann Restart-Probleme lösen. Wenn man diese Probleme nicht hat, sollte man das Attribut nicht setzen.
			</li>
			<li><b>rescanNetworkInterval</b><br />
				Default = 0<br />
				In Minuten. Ist zum Test. Das RescanNetwork kann per Zeitintervall wiederholt werden. Dabei wird der komplette Controlpoint gestoppt und wieder neu gestartet.
			</li>
			<li><b>startUpnpSearchInterval</b><br />
				Default = 0<br />
				In Minuten. Ist zum Test. Das StartUpnpSearch kann per Zeitintervall wiederholt werden. Dabei wird die Upnp Suche gestoppt und wieder neu gestartet.
			</li>
			<li><b>expert</b><br />
				Default = 0<br />
				Aktiviert zusätzliche Funktionen für die Diagnose:<br />
				<ul>
					<b>Set</b>
					<ul>
						<li><b>xxxxxxx</b><br />
							xxxxxxx<br />
							Dient hauptsächlich der schnellen Diagnose.
						</li>
					</ul>
					<b>Get</b>
					<ul>
						<li><b>xxxxxxx</b><br />
							xxxxxxx<br />
							Dient hauptsächlich der schnellen Diagnose, ohne das verbose = 5 gesetzt werden muss.
						</li>
					</ul>
				</ul>
			</li>
  		</ul>
  	</ul><br />
  	<ul>
		TV<br />
		<ul>
			<li><b>authKey</b><br />
				Gespeicherter authKey. Wird beim Pairing ermittelt. Muss mit Save config gespeichert werden.
			</li>
			<li><b>deviceID</b><br />
				Gespeicherter deviceID. Wird beim Pairing ermittelt. Muss mit Save config gespeichert werden.
			</li>
			<li><b>defaultChannelList</b><br />
				Es kann eine default ChannelList angegeben werden. Ist Experimentell, bisher keine andere als 'all' als Standard zurückgemeldet. 
			</li>
			<li><b>defaultFavoriteList</b><br />
				Es kann eine default FavoriteList angegeben werden. Es kann eine id, eine ownId oder der name der FavoriteList angegeben werden. Damit wird im SET nur die, in dieser Liste gespeicherten, Sender angezeigt.
			</li>
			<li><b>macAddress</b><br />
				Gespeicherter MAC Adresse. Wird beim erster Verbindung zum Fernseher ermittelt. Muss mit Save config gespeichert werden.
			</li>
			<li><b>pingTimeout</b><br />
				Default = 1s<br />
				Ist das Timeout für den Ping, welcher prüft, ob der TV über das Netzwerk erreichbar ist. 
			</li>
			<li><b>pollingInterval</b><br />
				Default = 30<br />
				Nach einer Zufallszeit aus 30 + 10s erfolgt der nächste Aufruf zur Abfrage von Daten. Wenn keine Senderinformationen des gerade laufenden Senders notwendig sind, kann auch 0 gewählt werden. Damit erfolgt kein Polling. EIN/AUS wird über Upnp erkannt.
			</li>
			<li><b>renewSubscription</b><br />
				Ist eher für Tester gedacht. Ist die Zeit in s (60s...300s) für die Erneuerung der Subscription.
			</li>
			<li><b>requestTimeout</b><br />
				Default = 2s<br />
				Ist das Timeout für einen http-Request. Je kleiner, um so kürzer sind die Freezes während fehlgeschlageener http-Requests.
			</li>
			<li><b>expert</b><br />
				Default = 0<br />
				Aktiviert zusätzliche Funktionen für die Diagnose:<br />
				<ul>
					<b>Set</b>
					<ul>
						<li><b>xxxxxxx</b><br />
							xxxxxxx<br />
							Dient hauptsächlich der schnellen Diagnose.
						</li>
					</ul>
					<b>Get</b>
					<ul>
						<li><b>xxxxxxx</b><br />
							xxxxxxx<br />
							Dient hauptsächlich der schnellen Diagnose, ohne das verbose = 5 gesetzt werden muss.
						</li>
					</ul>
				</ul>
			</li>
		</ul>
  	</ul><br />
  	<b>Readings</b>
  	<ul>
    	PHILIPS<br />
		<ul>
			<li><b>state</b> - Status Upnp.</li>
		</ul><br />
		TV<br />
	    <ul>
			<li><b>ApplicationsCount</b> - Anzahl der verfügbaren Applicationen.</li>
			<li><b>ApplicationsVersion</b> - Version der Applictionsliste.</li>
			<li><b>ChannelCount</b> - Anzahl der Sender in der Senderliste wie ChannelList.</li>
			<li><b>ChannelList</b> - ID der Senderliste.</li>
			<li><b>ChannelListVersion</b> - Version der Senderliste.</li>
			<li><b>CurrentChannelList</b> - Aktuelle Senderliste (ID - NAME) der Favoriten.</li>
			<li><b>CurrentChannelListVersion</b> - Aktuelle Senderlistenversion der Favoriten.</li>
			<li><b>CurrentChannelName</b> - Aktueller Sendername.</li>
			<li><b>CurrentChannelNo</b> - Aktuelle Sendernummer - Ist die aus der angezigten ChannelList.</li>
			<li><b>Mute</b> - Stummschalten.</li>
			<li><b>Powerstate</b> - Powerstate.</li>
			<li><b>Storage</b> - Speicherstick.</li>
			<li><b>Volume</b> - Lautstärke.</li>
			<li><b>authKey</b> - Wird beim Pairing ermittelt.</li>
			<li><b>deviceID</b> - Wird beim Pairing ermittelt.</li>
		</ul>
  	</ul><br />
</ul>

=end html_DE

=cut