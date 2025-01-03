// Datum for handling bug reports
#define STATUS_SUCCESS 201

/datum/tgui_bug_report_form
	/// contains all the body text for the bug report.
	var/list/bug_report_data = null

	/// client of the bug report author, needed to create the ticket
	var/client/initial_user = null
	// ckey of the author
	var/initial_key = null // just incase they leave after creating the bug report

	/// client of the admin who is accessing the report, we don't want multiple admins unknowingly making changes at the same time.
	var/client/admin_user = null

	/// value to determine if the bug report is submitted and awaiting admin approval, used for state purposes in tgui.
	var/awaiting_admin_approval = FALSE

	// for garbage collection purposes.
	var/selected_confirm = FALSE

/datum/tgui_bug_report_form/New(mob/user)
	initial_user = user.client
	initial_key = user.client.key

/datum/tgui_bug_report_form/proc/external_link_prompt(client/user)
	tgui_alert(user, "Unable to create a bug report at this time, please create the issue directly through our GitHub repository instead")
	var/url = CONFIG_GET(string/githuburl)
	if(!url)
		to_chat(user, SPAN_WARNING("The configuration is not properly set, unable to open external link"))
		return

	if(tgui_alert(user, "This will open the GitHub in your browser. Are you sure?", "Confirm", list("Yes", "No")) == "Yes")
		user << link(url)

/datum/tgui_bug_report_form/ui_state()
	return GLOB.always_state

/datum/tgui_bug_report_form/tgui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BugReportForm")
		ui.open()

/datum/tgui_bug_report_form/ui_close(mob/user)
	. = ..()
	if(!admin_user && user.client == initial_user && !selected_confirm) // user closes the ui without selecting confirm or approve.
		qdel(src)
		return
	admin_user = null
	selected_confirm = FALSE

/datum/tgui_bug_report_form/Destroy()
	GLOB.bug_reports -= src
	return ..()

/datum/tgui_bug_report_form/proc/sanitize_payload(list/params)
	for(var/param in params)
		params[param] = sanitize(params[param], list("\t"=" ","�"=" ","<"=" ",">"=" ","&"=" "))

	return params

// whether or not an admin can access the record at a given time.
/datum/tgui_bug_report_form/proc/assign_admin(mob/user)
	if(!initial_key)
		to_chat(user, SPAN_WARNING("Unable to identify the author of the bug report."))
		return FALSE
	if(admin_user)
		if(user.client == admin_user)
			to_chat(user, SPAN_WARNING("This bug report review is already opened and accessed by you."))
		else
			to_chat(user, SPAN_WARNING("Another administrator is currently accessing this report, please wait for them to finish before making any changes."))
		return FALSE
	if(!CLIENT_IS_STAFF(user.client))
		message_admins("[user.ckey] has attempted to review [initial_key]'s bug report titled [bug_report_data["title"]] without proper authorization at [time2text(world.timeofday, "YYYY-MM-DD hh:mm:ss")].")
		return FALSE

	admin_user = user.client
	return TRUE

// returns the body payload
/datum/tgui_bug_report_form/proc/create_form()
	var/datum/getrev/revdata = GLOB.revdata
	var/test_merges
	if(length(revdata.testmerge))
		test_merges = revdata.GetTestMergeInfo(header = FALSE)

	var/desc = {"
## Testmerges
[test_merges ? test_merges : "N/A"]

## Round ID
[GLOB.round_id ? GLOB.round_id : "N/A"]

## Description of the bug
[bug_report_data["description"]]

## What's the difference with what should have happened?
[bug_report_data["expected_behavior"]]

## How do we reproduce this bug?
[bug_report_data["steps"]]

## Attached logs
```
[bug_report_data["log"] ? bug_report_data["log"] : "N/A"]
```

## Additional details
- Author: [initial_key]
- Admin: [admin_user]
- Note: [bug_report_data["admin_note"] ? bug_report_data["admin_note"] : "None"]
	"}

	return desc

// the real deal, we are sending the request through the api.
/datum/tgui_bug_report_form/proc/send_request(payload_body, client/user)
	// for any future changes see https://docs.github.com/en/rest/issues/issues
	var/repo_name = CONFIG_GET(string/repo_name)
	var/org = CONFIG_GET(string/org)
	var/token = CONFIG_GET(string/github_app_api)

	if(!token || !org || !repo_name)
		tgui_alert(user, "The configuration is not set for the external API.", "Issue not reported!")
		external_link_prompt(user)
		qdel(src)
		return

	var/url = "https://api.github.com/repos/[org]/[repo_name]/issues"
	var/list/headers = list()
	headers["Authorization"] = "Bearer [token]"
	headers["Content-Type"] = "text/markdown; charset=utf-8"
	headers["Accept"] = "application/vnd.github+json"

	var/datum/http_request/request = new()
	var/list/payload = list(
		"title" = bug_report_data["title"],
		"body" = payload_body,
		"labels" = list("Bug")
	)

	request.prepare(RUSTG_HTTP_METHOD_POST, url, json_encode(payload), headers)
	request.begin_async()
	UNTIL_OR_TIMEOUT(request.is_complete(), 5 SECONDS)

	var/datum/http_response/response = request.into_response()
	if(response.errored || response.status_code != STATUS_SUCCESS)
		message_admins(SPAN_ADMINNOTICE("The GitHub API has failed to create the bug report titled [bug_report_data["title"]] approved by [admin_user], status code:[response.status_code]. Please paste this error code into the development channel on discord."))
		external_link_prompt(user)
	else
		message_admins("[user.ckey] has approved a bug report from [initial_key] titled [bug_report_data["title"]] at [time2text(world.timeofday, "YYYY-MM-DD hh:mm:ss")].")
		to_chat(initial_user, SPAN_WARNING("An admin has successfully submitted your report and it should now be visible on GitHub. Thanks again!"))
	qdel(src)// approved and submitted, we no longer need the datum.

// proc that creates a ticket for an admin to approve or deny a bug report request
/datum/tgui_bug_report_form/proc/bug_report_request()
	to_chat(initial_user, SPAN_WARNING("Your bug report has been submitted, thank you!"))
	GLOB.bug_reports += src

	var/general_message = "[initial_key] has created a bug report, you may find this report directly in the ticket panel. Feel free modify the issue to your liking before submitting it to GitHub."
	GLOB.admin_help_ui_handler.perform_adminhelp(initial_user, general_message, urgent = FALSE)

	var/href_message = ADMIN_VIEW_BUG_REPORT(src)
	initial_user.current_ticket.AddInteraction(href_message)

/datum/tgui_bug_report_form/ui_act(action, list/params, datum/tgui/ui)
	. = ..()
	if (.)
		return
	var/mob/user = ui.user
	switch(action)
		if("confirm")
			if(selected_confirm) // prevent someone from spamming the approve button
				to_chat(user, SPAN_WARNING("you have already confirmed the submission, please wait a moment for the API to process your submission."))
				return
			bug_report_data = sanitize_payload(params)
			selected_confirm = TRUE
			// bug report request is now waiting for admin approval
			if(!awaiting_admin_approval)
				bug_report_request()
				awaiting_admin_approval = TRUE
			else // otherwise it's been approved
				var/payload_body = create_form()
				send_request(payload_body, user.client)
		if("cancel")
			if(awaiting_admin_approval) // admin has chosen to reject the bug report
				reject(user.client)
			qdel(src)
	ui.close()
	. = TRUE

/datum/tgui_bug_report_form/ui_data(mob/user)
	. = list()
	.["report_details"] = bug_report_data // only filled out once the user as submitted the form
	.["awaiting_admin_approval"] = awaiting_admin_approval

/datum/tgui_bug_report_form/proc/reject(client/user)
	message_admins("[user.ckey] has rejected a bug report from [initial_key] titled [bug_report_data["title"]] at [time2text(world.timeofday, "YYYY-MM-DD hh:mm:ss")].")
	to_chat(initial_user, SPAN_WARNING("An admin has rejected your bug report, this can happen for several reasons. They will most likely get back to you shortly regarding your issue."))

#undef STATUS_SUCCESS
