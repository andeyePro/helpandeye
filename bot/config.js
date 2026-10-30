// Everything the bot knows about the site it answers for. This is the only file that names the
// site: edit it for your own, and leave the rest of the bot alone.
export default {
  siteName: "Help&I",
  siteUrl: "https://help.andeye.com",

  // Shown under every answer, and given to the model as a rule it must repeat whenever anyone
  // asks about an emergency. Keep it if your site is anything like this one.
  safetyLine: "Help&I does not replace 999 or telecare. In an emergency, call 999 first if you can.",

  // What the bot says when the content below does not answer a question.
  elsewhere: "Ask in Discussions at https://github.com/andeyePro/helpandeye/discussions.",

  // The site's content and FAQ, as plain text. The model answers only from this, so anything
  // not here is "I don't know". Keep it in step with the site.
  content: `# Help&I

Help&I is in development and not yet available. It is free and open-source. Nothing here is
ready to rely on yet.

Help&I is a resilient call-for-help system: press a button and reach people you have chosen,
over whatever still works: your home Wi-Fi, the internet, your mobile phone network, other
mobile phone networks (if your phone has a SIM that can use them), or a local radio network
where your community has set one up.

Help&I does not replace 999. In an emergency, call 999 first if you can. Help&I adds to your
telecare alarm, your phone and any lone-working arrangements you already have. It does not
replace them.

Help&I is an andeye Ltd project (registered in Scotland, SC665704). Website:
https://help.andeye.com. Code: https://github.com/andeyePro/helpandeye. Questions:
https://github.com/andeyePro/helpandeye/discussions. You can join the waitlist or volunteer
from the website. Help is welcome: hardware development, software development, testing,
advice, or simply an idea.

## Who it helps

You choose who answers: family, neighbours, a volunteer rota or your own team.

- Neighbours: someone nearby knows when you need them, even if your telecare alarm has stopped
  working in a power cut (needs a local radio network). A household chooses a few people to
  answer. If the first person does not reply, the request goes to the next. It sits alongside
  a telecare alarm, not instead of it.
- People out on their own: farmers, walkers and lone workers can check in and call for help.
  Set check-in times and choose who is told if you miss one. Help&I needs a mobile signal, or
  a local radio network within range, to get a message out. In remote country with neither,
  it cannot get through; satellite messaging is being looked at for those places.
- Communities: a street, village or valley can keep in touch and look after each other through
  an outage (needs a local radio network). A community can set up its own radio relays, mains
  powered with battery and optional solar backup, and a rota of volunteers to answer. In a
  long outage, responders see one summary of who is on battery and who has asked for help,
  not a flood of alarms.
- Teams: a simple way to call for a hand at a site or an event. A site, farm or event can give
  each person the app or a pendant and make the team the responders. Button labels can
  change, so green might mean "checked in". It is not a certified lone-worker service.

## Three buttons

- Red (large): help. Starts a call for help to the people you chose.
- Amber (small): need a hand. For things that can wait a little while.
- Green (small): I'm OK. Lets everyone know you are fine.

Use them on your phone, on your watch, or on a small box or pendant. After the first press,
the phone can ask a few simple follow-up questions so the people coming know what to expect.

## What you can count on

- Help is confirmed by a person. You are only told help is coming when someone has read your
  message and said so. Nothing confirms help automatically.
- You will know if it did not get through: the screen shows a cross, so you can try again or
  use another way. There is no "delivered" tick.
- The box keeps working in a power cut (needs a local radio network to send without a phone).
  It runs on its battery and can let people know the power is off, long before it runs low.
- Check in if you want to: agree times to press green, and someone is asked to look in if you
  miss one. It is off unless you turn it on.
- Falls detected by a watch: planned, so that a fall reaches the people who can help even if
  you cannot press anything.

## Why now

Landlines are moving to digital. Many telecare alarms now need mains power and broadband, so
they can stop working in a power cut. Mobile masts often lose power within hours.

## How it gets through

A call goes out at once over every route that works:

1. Over your home Wi-Fi, straight to the others of your group at home, with no internet.
2. Over the internet, while it works.
3. Over your mobile phone network. An iPhone cannot send a text by itself, so if the other
   ways have failed it offers you one to tap Send on.
4. Over other mobile phone networks, if your phone has a SIM that can use them.
5. Over a local radio network, where your community has set one up. It runs on mains power,
   with battery and optional solar backup, and needs no licence. It uses licence-exempt
   868 MHz LoRa radio (MeshCore mesh) and stays within Ofcom limits.

Your privacy: the people who answer see your name from their own list of the people they look
after. The call for help itself carries only a code, so a stranger listening cannot tell who
needed help. Anything you type, a choice such as "Fallen", and where you are, is locked so
that only the people answering can read it. Names, addresses and medical details are never
sent over the air.

Standards: Help&I is being designed to meet the British standards for lone-worker services
(BS 8484) and alarm handling (BS 9518). It is not certified yet, and nothing should be read
as if it were.

## Be clear what you have

Help&I is not magic. What it can reach depends on which parts you use and what your area has
set up.

- The app on its own works while your phone has internet or a mobile signal, and at home over
  your Wi-Fi to the others of your group there. Like any phone, it cannot send when all of
  those are down.
- A Help&I box or pendant is a small radio with the three buttons. It keeps running on its
  battery in a power cut, and sends over the local radio network where there is one, or
  through your phone when the phone is nearby. Your phone goes out with you; the box stays at
  home. The box is a standard Heltec LoRa board. Prototypes are not yet tested on real
  hardware.
- A local radio network only exists where local volunteers have set one up. Its relays run on
  mains power, with battery and optional solar backup. Without one, a box can only send
  through your phone.

Help&I tells you when someone has replied, and shows a cross if your message could not get
through. Help only comes if a person you have chosen is there to answer.

## Questions people ask

Can I get Help&I yet? Not yet. It is being built and tested, and nothing here is ready to
rely on. Join the waitlist to hear when it is.

Does it replace 999 or my telecare alarm? No. Help&I adds to 999, NHS 111, telecare and any
lone-working procedure you already have. In an emergency, call 999 first if you can.

Do I need the box? No. The app on its own works while your phone has internet or a mobile
signal, and at home over your Wi-Fi to the others of your group there. The box adds buttons
that work without a phone and keep working in a power cut, and the local radio network where
there is one.

What happens in a power cut? The box runs on its battery and can tell the people you chose
that the power is off, long before it runs low. It sends over the local radio network where
there is one, or through your phone while the phone has a signal. Without either, a message
cannot get out, and the box shows a cross.

Who answers when I press the button? The people you chose: family, neighbours, a volunteer
rota or your own team. There is no call centre. If the first person does not reply, the
request goes to the next. Help only comes if one of them is there to answer.

How will I know someone is coming? You are only told help is coming when one of your people
has read your message and said so. If your message could not get through, the screen shows a
cross, so you can try again or use another way.

What is sent, and who can see it? The call for help carries only a code, so a stranger
listening cannot tell who needed help. The people who answer see your name from their own
list. Anything you choose to add, such as a short message, "Fallen" or where you are, is
locked so that only the people answering can read it.

Which phones and watches will it work on? iPhone and Apple Watch first. Android is planned,
and a volunteer Android developer would help it come sooner.

Is there a local radio network near me? Only where local volunteers have set one up. It uses
small radio relays that need no licence, on mains power with battery and optional solar
backup. A community can build its own; tell us if yours would like to.

Is it certified? Not yet. We are designing it to meet the British standards for lone-worker
services and alarm handling, and nothing here should be read as if it were certified.

I have another question. Ask in Discussions. Mention @claude there for an answer from
Claude, Anthropic's AI assistant, or wait for one of the team. People building Help&I can
also read the developer FAQ in the repository.
`,
};
