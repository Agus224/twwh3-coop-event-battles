"""Apply the Co-op Event Battles change to the game's multiplayer blocker layout.

Usage: python tools/patch_blocker_layout.py ui_src/mp_pending_action_blocking_msg.twui.xml

The file itself belongs to Creative Assembly and is not redistributed here: extract
"ui/campaign ui/mp_pending_action_blocking_msg.twui.xml" from data/ui3.pack (for example with
RPFM) and run this script on the copy. The mod only adds one condition to two context functions,
so the "another player is deciding" blocker hides while the mod's own army picker is open
(the script sets the context value ceb_ui_open to 1 while it shows it).
"""
import sys
from pathlib import Path

CONDITION = ' &amp;&amp; ScriptObjectContext(&quot;ceb_ui_open&quot;).NumericValue == 0'
TARGETS = [
    'context_function_id="IsBlockingLocalPlayer &amp;&amp; CampaignRoot.IsCinematicModeEnabled == false &amp;&amp; ShouldBlockAllInteractions"',
    'context_function_id="ShouldBlockAllInteractions"',
]

def patch(text):
    if CONDITION in text:
        return text, 0
    count = 0
    for target in TARGETS:
        if text.count(target) != 1:
            raise SystemExit('Unexpected layout: %r found %d times (game update?)' % (target, text.count(target)))
        text = text.replace(target, target[:-1] + CONDITION + '"')
        count += 1
    return text, count

if __name__ == '__main__':
    path = Path(sys.argv[1])
    data = path.read_bytes().decode('utf-8')
    patched, count = patch(data)
    if count:
        path.write_bytes(patched.encode('utf-8'))
        print('Patched %d context functions in %s' % (count, path))
    else:
        print('Already patched:', path)
