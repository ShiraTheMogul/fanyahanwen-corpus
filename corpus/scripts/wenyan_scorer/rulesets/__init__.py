"""Rulesets. Each module exposes a `RULES: list[Rule]`.

To add one, write the module and register it in `wenyan_syntax.rules._RULESETS`.
It is loaded only if named in `--rulesets`, so a new ruleset cannot change
anyone's scores until it is asked for.
"""
