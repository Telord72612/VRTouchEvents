# VRTouchEvents
SkyrimNet plugins for SkyrimVR touch or grab detection to be push to LLM for awareness reaction 

Requirement :

SkyrimNet (and all it's requirement)

VRIK (https://www.nexusmods.com/skyrimspecialedition/mods/23416)
HIGGS (https://www.nexusmods.com/skyrimspecialedition/mods/43930)
PLANCK (https://www.nexusmods.com/skyrimspecialedition/mods/66025)
CBPC - Physic and Collissions for SSE (https://www.nexusmods.com/skyrimspecialedition/mods/21224)		
CBBE 3BA(optional i think) (https://www.nexusmods.com/skyrimspecialedition/mods/30174)
More haptics CBPC VR config (https://www.nexusmods.com/skyrimspecialedition/mods/40749) I highly recommend to remove the NPCEyeBone if you are using MfgFix, it prevent eye movement from NPC for other mod to use
Fluffy M'rissi Replacer (optional) (https://www.nexusmods.com/skyrimspecialedition/mods/53654)
If you got all of those, you should have all the proper requirement to make this plugins work. 

BIG DISCLAIMER: This is Vibe coded with Opus 4.7. For real, Claude Code is fucking magical

Explanation: This mod is a VR focused mod that integrate touch and grab from the Player to a NPC, detect which part of the bodies got interacted with, what does the NPC wear at that specific body slot, and fire a event trigger to let the NPC know and be aware of the interaction between the player and NPC. It come with delay to specific part according to what is the NPC wearing and where are they being touched.
A NPC that get touch on her chest while wearing Heavy Armor on slot 32 will be told that the PLayer touched their (Heavy Armor's name) on their chest after the player made contact with that part for more than 4 second, compared to being naked, where she will be told that the player touched her naked left breast and will be told almost immediately about it. No accidental boob touch in life, same in VR.

How it work. By using CBPC and "more haptic VR CBPC", i was able to get Claude to figure out how to make new touch node and leaf and add them to CBPC config, to make them detectable with VRIK and HIGGS, so that VRTouchEvents can send SkyrimNet triggers events to let the LLM know where they got touched, how, and what they are wearing at that location, so they can react properly. I used a bunch of existing CPBC contact node and made a bunch of new one. Breast, belly and butt (3BBB) is done by SMP. I haven't tested with just CBPC, but it should work with it.


There is a total of 17 body parts that can be touched : Head,Face,hands,arms,foot,legs,L&R breast,chest,belly,upper back,lower back,butt,genitals,tails upper,tails lower, and neck for choking.
Each parts have a specific delay according to their current equipped slot gear on that body part, using head(30),mask(44), hand(33),arms(34),foor(37),body(32),butt/genital(32,49&52). 

Touching or grabing someone wearing heavy armor will take longer to be detected compared to someone being naked. Detected dress state is Bare,clothes,Light Armor & Heavy armor. Touching bare and clothes just state the cloths. Touch/grab armor will state the name of the armor piece being touched/grabbed.

There is a global cooldown of 15 second between touch or grab events for that NPC, so that multiple place on the body won't spam events all at once. The first one that fire will prevent any touch/grab events for 15 second for that NPC. Except for interrupting touch/grab
The interrupting touch/grab for the NPC action are as follow: touching/grabbing breast/butt bare or clothed, and touching/grabbing  genitals, any dress state, and choking. Those action are considered important enough that it should stop any action the NPC is doing and should make them react right away.

Khajiit and Argonian tails can be touched. I added CPBC node for them to be detected. It work with vanilla and HDT-SMP tails.
Bonus, If you download "Fluffy M'rissi Replacer", her tails can be moved around a bit. Not a lots, but you can see it swing with your touch, and she will react to that when you touch it. No grabbing, there is no real skeleton node and that would have been too much change, could potentially break all animation for herself. Technically HDT-SMP Tails move too, but the XML file are made to have them being fairly heavy, so it's barely noticeable when you touch them. Make them move more would be equivalent to changing a lot of the physic in general. Fluffy m'rissi's tail is more light and move around a lot, so it's affected by the touch more and way more noticeable. 

CHOCKING: there is a added feature where NPC can be choked by the player. If you grab any NPC Neck, after 2sec, a choking sound will play and the will become unconscious and ragdoll after 15sec. And of you keep holding, they will die after 25 sec. Grabbing the neck is REALLY HARD for just cause. You really need to lift the chin up and grab at the neck, almost making sure your thumb is on one side and your finger are on the other side of the throat. If you don't hear choking after 2 sec, you missed. There is a 1 sec delay before it start for forgiveness, but it's so hard to do that it's almost not needed.

There is multiple stage to choking:
-less than 1 sec: no consequence
-2 to 3 sec choking: on release, NPC will be told that you grabbed their neck and squeezed
-3 to 7 sec choking: on release, NPC will be told that you grabbed their neck and squeezed hard enough to create pain and make them unable to breath
-at 7 sec: NPC will become hostile and fight you while holding them if their relationship is less than 1
-7 to 15 sec choking: on release, NPC will be told that you grabbed their neck and squeezed hard enough to create  lasting pain and make them unable to breath to almost bring you to a passout point.
-at 10 sec: if relationship is less than 2, a "SendAssaultAlarm()" is sent to friendly faction member if any of the friend of the choked NPC are around and can see you, like guards or fighting faction. If you are not in stealth mode and unseen, the assault alarm won't be sent.  There will also be a general SkyrimNet events posted for awareness of NPC around you to see what you are doing, in case you are surrounded by friendly that won't attack, they will at least be aware. 
-at 15 sec: NPC will ragdoll and become uncounsious. Choking noise will stop. The "SendAssaultAlarm()" will be removed if you didn't get detected while choking. The NPC being choked will stop being hotile.
-at 25 sec: the NPC, if still being choked, will die if they are not protected/essential

Choking an NPC is considered an aggression. I'm sure there is NPC that will enjoy having it according to their bio/personality, but if you release before 7 second, it will be fine, no hostility/assault will be triggered. And if they passout, all the hostility/alarms get removed if no one else seen you. At a minimun of relationship 2 with that NPC, they the assault alarm won't triggers, as it's a "serious" fight between friend. 

If you are hiding during the choke and no NPC can see you, excluding the NPC being choked, no assault alarm will get triggered if the NPC end up passing out.

Any NPC choked will be so between 2 to 4 ingame hour, with a penality of 50% health and no regen while passout. They can be made to regain consciousness with a healing spell or a potion. 

There is a total of 10 tracked slot for passout NPC. If you remove the mod while passout NPC are around, they may not come back, or get their regen back, so be mindful of that.

As i stated at the beginning, i understand how the mod work and it's mechanic, but i didn't do the Code, it's was all done by Opus 4.7, so i'm not sure how safe this is. I'm playing with it, and my mod list is super heavy, 2000mod with physic, AI, fur shaders, the full CS suit, and i didn't had any issue. If there is any bug, let me know and i'll see what i can do, but it's VR, and VR is super clunky in general, so i might not be able to do much.

Anyway, hope you guy enjoy it. I certainly enjoy petting M'rissi's tail


