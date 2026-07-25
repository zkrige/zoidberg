"""Shim: re-export lib package functions as the whatsapp module for main.py.
Missing functions are stubbed with NotImplementedError to allow the server to start.
"""
from lib.bridge import (
    send_message, send_file, send_reaction, edit_message, delete_message,
    mark_read, get_group_info, create_group, create_poll, send_typing,
    set_about_text, set_disappearing_timer, get_privacy_settings,
    pin_chat, mute_chat, archive_chat, download_media,
)
from lib.database import (
    list_messages, list_chats, get_message_context,
    get_contact_by_jid, get_contact_nickname, set_contact_nickname,
    search_contacts,
)

# Alias
mark_messages_read = mark_read

def _stub(name):
    def fn(*args, **kwargs):
        raise NotImplementedError(f"{name} not implemented in this build")
    fn.__name__ = name
    return fn

add_group_members = _stub("add_group_members")
remove_group_members = _stub("remove_group_members")
demote_admin = _stub("demote_admin")
promote_to_admin = _stub("promote_to_admin")
leave_group = _stub("leave_group")
update_group = _stub("update_group")
create_newsletter = _stub("create_newsletter")
follow_newsletter = _stub("follow_newsletter")
unfollow_newsletter = _stub("unfollow_newsletter")
get_last_interaction = _stub("get_last_interaction")
get_contact_by_phone = _stub("get_contact_by_phone")
get_contact_chats = _stub("get_contact_chats")
get_direct_chat_by_contact = _stub("get_direct_chat_by_contact")
list_all_contacts = _stub("list_all_contacts")
list_contact_nicknames = _stub("list_contact_nicknames")
remove_contact_nickname = _stub("remove_contact_nickname")
get_blocklist = _stub("get_blocklist")
update_blocklist = _stub("update_blocklist")
request_chat_history = _stub("request_chat_history")
set_presence = _stub("set_presence")
subscribe_presence = _stub("subscribe_presence")
get_profile_picture = _stub("get_profile_picture")
get_chat = _stub("get_chat")
send_audio_message = _stub("send_audio_message")
