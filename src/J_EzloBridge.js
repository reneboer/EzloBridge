var EzloBridge = (function (api) {
    var _uuid = '12021512-0000-a0a0-b0b0-c0c030303136';
	var VB_SID = 'urn:akbooer-com:serviceId:EzloBridge1';
	var bOnALTUI = true;
	var DIV_PREFIX = "vbEzloBridge_";	// Used in HTML div IDs to make them unique for this module
	var MOD_PREFIX = "EzloBridge";  // Must match module name above

	// Forward declaration.
    var myModule = {};
	
    function _onBeforeCpanelClose(args) {
		showBusy(false);
        //console.log('EzloBridge, handler for before cpanel close');
    }

    function _init() {
        // register to events...
        api.registerEventHandler('on_ui_cpanel_before_close', myModule, 'onBeforeCpanelClose');
    }
	
	// Return HTML for settings tab
	function _Settings() {
		_init();
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var hubList = [{'value':'/port_3480','label':'Vera Hub'},{'value':'3480','label':'openLuup'},{'value':'17000','label':'Ezlo Hub'}];
			var hmmList = [{'value':'0','label':'No mirroring'},{'value':'1','label':'Local mirrors Remote'},{'value':'2','label':'Remote mirrors Local'}];
			var yesNo = [{'value':'0','label':'No'},{'value':'1','label':'Yes'}];
			var logLevel = [{'value':'1','label':'Error'},{'value':'2','label':'Warning'},{'value':'8','label':'Info'},{'value':'10','label':'Debug'},{'value':'101','label':'Develop'}];
			var html = '<div class="deviceCpanelSettingsPage">'+
				'<h3>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'</h3>';
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				html += '<br>Plugin is disabled in Attributes.</div>';
			} else {
				var curSystem = varGet(deviceID, 'RemotePort');
				var deviceObj = api.getDeviceObject(deviceID);
				var ip = !!deviceObj.ip ? deviceObj.ip : '';
				html +=	htmlAddInput(deviceID, 'Ezlo Hub IP Address', 20, 'IPAddress', VB_SID, ip) + 
//				htmlAddPulldown(deviceID, 'Remote Hub Type', 'RemotePort', hubList)+
//				'<div id="'+DIV_PREFIX+deviceID+'div_system_vera" style="display: '+((curSystem !== '17000')?'block':'none')+';" >'+
//				htmlAddPulldown(deviceID, 'Async Polling', 'AsyncPoll', yesNo)+
//				htmlAddPulldown(deviceID, 'Only Zwave devices', 'ZWaveOnly', yesNo)+
//				'</div>'+
//				'<div id="'+DIV_PREFIX+deviceID+'div_system_ezlo" style="display: '+((curSystem === '17000')?'block':'none')+';" >'+
				htmlAddInput(deviceID, 'Ezlo Hub Serial', 20, 'HubSerial')+
				htmlAddInput(deviceID, 'Ezlo Hub User ID', 20, 'UserID')+
				htmlAddPwdInput(deviceID, 'Ezlo Hub Password', 20, 'Password')+
//				'</div>'+
				htmlAddPulldown(deviceID, 'House Mode Mirroring', 'HouseModeMirror', hmmList)+
				htmlAddPulldown(deviceID, 'Bridge Scenes', 'BridgeScenes', yesNo)+
				htmlAddPulldown(deviceID, 'Clone Rooms', 'CloneRooms', yesNo)+
				htmlAddPulldown(deviceID, 'Log level', 'LogLevel', logLevel)+
				htmlAddButton(deviceID, 'UpdateSettingsCB')+
				'</div>';
//				'<script>'+
//				' $("#'+DIV_PREFIX+'RemotePort'+deviceID+'").change(function() {'+
//				'   if($(this).val()!=17000){$("#'+DIV_PREFIX+deviceID+'div_system_ezlo").hide();$("#'+DIV_PREFIX+deviceID+'div_system_vera").show();};'+
//				'   if($(this).val()==17000){$("#'+DIV_PREFIX+deviceID+'div_system_vera").hide();$("#'+DIV_PREFIX+deviceID+'div_system_ezlo").show();};'+
//				' });'+
//				'</script>';
			}
			api.setCpanelContent(html);
        } catch (e) {
            Utils.logError('Error in '+MOD_PREFIX+'.Settings(): ' + e);
        }
	}
	
	function _UpdateSettingsCB(deviceID) {
		// Save variable values so we can access them in LUA without user needing to save
		showBusy(true);
		var ipa = htmlGetElemVal(deviceID, 'IPAddress');
		if (ipa != '') { api.setDeviceAttribute(deviceID, 'ip', ipa); }
//		var rp = htmlGetPulldownSelection(deviceID, 'RemotePort');
//		varSet(deviceID,'RemotePort',rp);
//		if (rp == 17000) {
			varSet(deviceID,'HubSerial',htmlGetElemVal(deviceID, 'HubSerial'));
			varSet(deviceID,'UserID',htmlGetElemVal(deviceID, 'UserID'));
			varSet(deviceID,'Password',htmlGetElemVal(deviceID, 'Password'));
//		} else {
//			varSet(deviceID,'AsyncPoll',htmlGetPulldownSelection(deviceID, 'AsyncPoll'));
//			varSet(deviceID,'ZWaveOnly',htmlGetPulldownSelection(deviceID, 'ZWaveOnly'));
//		}
		varSet(deviceID,'HouseModeMirror',htmlGetPulldownSelection(deviceID, 'HouseModeMirror'));
		varSet(deviceID,'BridgeScenes',htmlGetPulldownSelection(deviceID, 'BridgeScenes'));
		varSet(deviceID,'CloneRooms',htmlGetPulldownSelection(deviceID, 'CloneRooms'));
		varSet(deviceID,'LogLevel',htmlGetPulldownSelection(deviceID, 'LogLevel'));
		application.sendCommandSaveUserData(true);
		setTimeout(function() {
			doReload(deviceID);
			showBusy(false);
			try {
				api.ui.showMessagePopup(Utils.getLangString("ui7_device_cpanel_details_saved_success","Device details saved successfully."),0);
			}
			catch (e) {
				Utils.logError(MOD_PREFIX+': UpdateSettings(): ' + e);
			}
		}, 3000);	
	}
	// Update variable in user_data and lu_status
	function varSet(deviceID, varID, varVal, sid) {
		if (typeof(sid) == 'undefined') { sid = VB_SID; }
		api.setDeviceStateVariablePersistent(deviceID, sid, varID, varVal);
	}
	// Get variable value. When variable is not defined, this new api returns false not null.
	function varGet(deviceID, varID, sid) {
		try {
			if (typeof(sid) == 'undefined') { sid = VB_SID; }
			var res = api.getDeviceState(deviceID, sid, varID);
			if (res !== false && res !== null && res !== 'null' && typeof(res) !== 'undefined') {
				return res;
			} else {
				return '';
			}	
        } catch (e) {
            return '';
        }
	}
	// Standard update for plug-in pull down variable. We can handle multiple selections.
	function htmlGetPulldownSelection(di, vr) {
		var value = $('#'+DIV_PREFIX+vr+di).val() || [];
		return (typeof value === 'object')?value.join():value;
	}
	// Get the value of an HTML input field
	function htmlGetElemVal(di,elID) {
		var res;
		try {
			res=$('#'+DIV_PREFIX+elID+di).val();
		}
		catch (e) {	
			res = '';
		}
		return res;
	}
	// Add a label and pulldown selection
	function htmlAddPulldown(di, lb, vr, values) {
		try {
			var selVal = varGet(di, vr);
			var html = '<div id="'+DIV_PREFIX+vr+di+'_div" class="clearfix labelInputContainer">'+
				'<div class="pull-left inputLabel '+((bOnALTUI) ? 'form-control form-control-sm form-control-plaintext' : '')+'" style="width:280px;">'+lb+'</div>'+
				'<div class="pull-left customSelectBoxContainer">'+
				'<select id="'+DIV_PREFIX+vr+di+'" class="customSelectBox '+((bOnALTUI) ? 'form-control form-control-sm' : '')+'">';
			for(var i=0;i<values.length;i++){
				html += '<option value="'+values[i].value+'" '+((values[i].value==selVal)?'selected':'')+'>'+values[i].label+'</option>';
			}
			html += '</select>'+
				'</div>'+
				'</div>';
			return html;
		} catch (e) {
			Utils.logError(MOD_PREFIX+': htmlAddPulldown(): ' + e);
			return '';
		}
	}
	// Add a standard input for a plug-in variable.
	function htmlAddInput(di, lb, si, vr, sid, df) {
		var val = (typeof df != 'undefined') ? df : varGet(di,vr,sid);
		var html = '<div id="'+DIV_PREFIX+vr+di+'_div" class="clearfix labelInputContainer" >'+
					'<div class="pull-left inputLabel '+((bOnALTUI) ? 'form-control form-control-sm form-control-plaintext' : '')+'" style="width:280px;">'+lb+'</div>'+
					'<div class="pull-left">'+
						'<input class="customInput '+((bOnALTUI) ? 'altui-ui-input form-control form-control-sm' : '')+'" size="'+si+'" id="'+DIV_PREFIX+vr+di+'" type="text" value="'+val+'">'+
					'</div>'+
				'</div>';
		return html;
	}
	// Add a standard input for password a plug-in variable.
	function htmlAddPwdInput(di, lb, si, vr, sid, df) {
		var val = (typeof df != 'undefined') ? df : varGet(di,vr,sid);
		var html = '<div id="'+DIV_PREFIX+vr+di+'_div" class="clearfix labelInputContainer" >'+
					'<div class="pull-left inputLabel '+((bOnALTUI) ? 'form-control form-control-sm form-control-plaintext' : '')+'" style="width:280px;">'+lb+'</div>'+
					'<div class="pull-left">'+
						'<input class="customInput '+((bOnALTUI) ? 'altui-ui-input form-control form-control-sm' : '')+'" size="'+si+'" id="'+DIV_PREFIX+vr+di+'" type="password" value="'+val+'">'+
					'</div>'+
				'</div>';
		html += '<div class="clearfix labelInputContainer '+((bOnALTUI) ? 'form-control form-control-sm form-control-plaintext' : '')+'">'+
					'<div class="pull-left inputLabel" style="width:280px;">&nbsp; </div>'+
					'<div class="pull-left '+((bOnALTUI) ? 'form-check' : '')+'" style="width:200px;">'+
						'<input class="pull-left customCheckbox '+((bOnALTUI) ? 'form-check-input' : '')+'" type="checkbox" id="'+DIV_PREFIX+vr+di+'Checkbox">'+
						'<label class="labelForCustomCheckbox '+((bOnALTUI) ? 'form-check-label' : '')+'" for="'+DIV_PREFIX+vr+di+'Checkbox">Show Password</label>'+
					'</div>'+
				'</div>';
		html += '<script type="text/javascript">'+
					'$("#'+DIV_PREFIX+vr+di+'Checkbox").on("change", function() {'+
					' var typ = (this.checked) ? "text" : "password" ; '+
					' $("#'+DIV_PREFIX+vr+di+'").prop("type", typ);'+
					'});'+
				'</script>';
		return html;
	}
	// Add a Save Settings button
	function htmlAddButton(di, cb) {
		html = '<div class="cpanelSaveBtnContainer labelInputContainer clearfix">'+	
			'<input class="vBtn pull-right btn" type="button" value="Save Changes" onclick="'+MOD_PREFIX+'.'+cb+'(\''+di+'\');"></input>'+
			'</div>';
		return html;
	}

	// Show/hide the interface busy indication.
	function showBusy(busy) {
		if (busy === true) {
			try {
					api.ui.showStartupModalLoading(); // version v1.7.437 and up
				} catch (e) {
					api.ui.startupShowModalLoading(); // Prior versions.
				}
		} else {
			api.ui.hideModalLoading(true);
		}
	}
	function doReload(deviceID) {
		api.performLuActionOnDevice(0, "urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {});
	}

	// Expose interface functions
    myModule = {
		// Internal for panels
        uuid: _uuid,
        init: _init,
        onBeforeCpanelClose: _onBeforeCpanelClose,
		UpdateSettingsCB: _UpdateSettingsCB,
		
		// For JSON calls
        Settings: _Settings,
    };
    return myModule;
})(api);