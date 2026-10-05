from better_profanity import profanity

# The library's list is tuned for chat, so it flags plenty that is ordinary at
# a race track: names (Dick, Willy, Van Dyke), brands (Hooker), parts and
# places (stroker, drag strip, lube), and mild grumbling in notes.
ALLOWED_WORDS = [
    "ass",
    "crap",
    "damn",
    "dick",
    "drunk",
    "dyke",
    "facial",
    "fanny",
    "fart",
    "gay",
    "god",
    "goddamn",
    "hell",
    "homo",
    "hooker",
    "hump",
    "jerk",
    "kill",
    "knob",
    "kum",
    "lmao",
    "lmfao",
    "lube",
    "lust",
    "moron",
    "muff",
    "murder",
    "naked",
    "nob",
    "omg",
    "organ",
    "pawn",
    "pee",
    "piss",
    "pissed",
    "poop",
    "pot",
    "queer",
    "rump",
    "screw",
    "screwed",
    "screwing",
    "snatch",
    "strip",
    "stroke",
    "stupid",
    "suck",
    "sucked",
    "thrust",
    "virgin",
    "weed",
    "willies",
    "willy",
    "woody",
    "wtf",
]

profanity.load_censor_words(whitelist_words=ALLOWED_WORDS)


def contains_blocked_word(*values: str | None) -> bool:
    return any(profanity.contains_profanity(value) for value in values if value)
