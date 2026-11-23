# Burnbot objective progress: can it be estimated from the logs?

**Verdict: not yet.** No estimator passed its test, so the chest bar stays off in the app and the chest keeps its normal lights. The furnace and the bar visuals are finished and wait on a future estimate (`objective` in the state JSON).

- **What exists in the logs.** The logs carry the request, follow-ups, plans (often approved in plan mode), tool calls, file edits, and check results. Explicit checklists are rare: under 1% of long turns.
- **How it was tested.** We stopped real past sessions at intermediate moments and showed each estimator only what existed then. We compared its answer with hindsight labels from Opus. GPT graded a blind 24-item set independently, to check the labels; GPT and Opus agree within 0.086.
- **Stage A.** 117 moments. Haiku is close mid-work (error 0.12), but wrong once Claude has handed back (0.28). It also shows a bar on 3 of 5 open-ended chats. Apple's on-device model does no better than a simple rule. The planned safety rules made Haiku worse, because its confidence does not track its error.
- **Confirmation round.** On 64 new moments, a working-only Haiku variant was fixed in advance. It failed: error 0.169 against a 0.15 limit, confidently wrong 16% against 10%, and only 10 open-ended moments against the 15 needed. A simple stage rule matched it at 0.168.
- **Where it fails.** Telling open-ended talk from a task. Knowing that a turn really finished. Follow-up prompts, where the error is highest.
- **Cost if shipped.** About $0.02 and 8 s per Haiku estimate.
- **Is the hybrid warranted?** Not on this evidence. To revisit, collect more open-ended sessions, then retest against the same gate.

Spend on the evaluation: about $16.6 (Stage A about $10.6, confirmation round $6.01). No `claude -p` run left a session in `~/.claude/projects`.

---

## Stage A (117 moments; rules, Haiku, on-device, GPT as independent grader)

Sample: 117 checkpoints; 112 bounded with a label (52 at handback, 60 mid-work); 5 open-ended frozen, 5 open-ended counting grader "no bar" answers.

### Against the hindsight (Opus) labels

| candidate | error, all | error, mid-work | error, handback | coverage | coverage, mid-work | confidently wrong | wrongly shown, open-ended |
|---|---|---|---|---|---|---|---|
| rule: const | 0.341 | 0.260 | 0.435 | 100% | 100% | 54% | 100% (n=5) |
| rule: stage | 0.240 | 0.224 | 0.258 | 100% | 100% | 21% | 100% (n=5) |
| rule: planfile | 0.276 | 0.238 | 0.320 | 100% | 100% | 29% | 100% (n=5) |
| rule: checklist | 0.338 | 0.289 | 0.633 | 6% | 10% | 57% | 0% (n=5) |
| haiku raw | 0.198 | 0.122 | 0.284 | 93% | 92% | 19% | 60% (n=5) |
| haiku hybrid | 0.244 | 0.181 | 0.332 | 49% | 53% | 25% | 0% (n=5) |
| ondevice raw | 0.273 | 0.233 | 0.319 | 100% | 100% | 31% | 100% (n=5) |
| ondevice hybrid | 0.335 | 0.254 | 0.424 | 88% | 87% | 43% | 60% (n=5) |

### Against the adjudicated labels

| candidate | error, all | error, mid-work | error, handback | coverage | coverage, mid-work | confidently wrong | wrongly shown, open-ended |
|---|---|---|---|---|---|---|---|
| rule: const | 0.328 | 0.252 | 0.415 | 100% | 100% | 53% | 100% (n=5) |
| rule: stage | 0.250 | 0.226 | 0.277 | 100% | 100% | 22% | 100% (n=5) |
| rule: planfile | 0.284 | 0.240 | 0.335 | 100% | 100% | 30% | 100% (n=5) |
| rule: checklist | 0.338 | 0.289 | 0.633 | 6% | 10% | 57% | 0% (n=5) |
| haiku raw | 0.186 | 0.113 | 0.267 | 93% | 92% | 16% | 60% (n=5) |
| haiku hybrid | 0.226 | 0.178 | 0.293 | 49% | 53% | 24% | 0% (n=5) |
| ondevice raw | 0.272 | 0.238 | 0.312 | 100% | 100% | 30% | 100% (n=5) |
| ondevice hybrid | 0.344 | 0.260 | 0.437 | 88% | 87% | 44% | 60% (n=5) |

Open-ended is weakly measured: n=5 (5 frozen by the labeller, 0 more that the independent grader marked "no bar"). On the 5 frozen ones alone: rule: const shown on 100%; rule: stage shown on 100%; rule: planfile shown on 100%; rule: checklist shown on 0%; haiku raw shown on 60%; haiku hybrid shown on 0%; ondevice raw shown on 100%; ondevice hybrid shown on 60%.

### Jitter between neighbouring checkpoints (same objective, both shown)

| candidate | pairs | bar moves back while truth doesn't | mean error of the change |
|---|---|---|---|
| rule: const | 56 | 0% | 0.339 |
| rule: stage | 56 | 12% | 0.366 |
| rule: planfile | 56 | 16% | 0.415 |
| rule: checklist | 4 | 50% | 0.508 |
| haiku raw | 50 | 10% | 0.194 |
| haiku hybrid | 25 | 8% | 0.264 |
| ondevice raw | 56 | 9% | 0.357 |
| ondevice hybrid | 47 | 15% | 0.373 |

### Independent grader (GPT)

24 graded; 3 marked "no bar" (0 of them where the hindsight label is bounded); of the 3 frozen open-ended items in the graded set, 3 marked "no bar".
Mean gap to the hindsight labels: 0.086 (n=21); to the adjudicated labels: 0.081. This is the label noise floor: above 0.15 the gate's error test cannot separate a good estimator from a bad one.

| candidate | n shown | error vs grader | coverage | wrongly shown on grader's no-bar items |
|---|---|---|---|---|
| rule: const | 21 | 0.300 | 100% | – (n=0) |
| rule: stage | 21 | 0.283 | 100% | – (n=0) |
| rule: planfile | 21 | 0.301 | 100% | – (n=0) |
| rule: checklist | 3 | 0.222 | 14% | – (n=0) |
| haiku raw | 20 | 0.050 | 95% | – (n=0) |
| haiku hybrid | 18 | 0.115 | 86% | – (n=0) |
| ondevice raw | 21 | 0.267 | 100% | – (n=0) |
| ondevice hybrid | 18 | 0.298 | 86% | – (n=0) |

### Calibration (model answers read directly: no checklist, no plan split)

| model | confidence | n | error | off by more than 0.3 |
|---|---|---|---|---|
| haiku | 0.0–0.5 | 7 | 0.229 | 14% |
| haiku | 0.5–0.7 | 26 | 0.246 | 27% |
| haiku | 0.7–0.8 | 28 | 0.186 | 14% |
| haiku | 0.8–0.9 | 5 | 0.140 | 20% |
| haiku | 0.9–1.0 | 4 | 0.400 | 50% |
| ondevice | 0.0–0.5 | 0 | – | – |
| ondevice | 0.5–0.7 | 1 | 0.100 | 0% |
| ondevice | 0.7–0.8 | 0 | – | – |
| ondevice | 0.8–0.9 | 0 | – | – |
| ondevice | 0.9–1.0 | 93 | 0.278 | 31% |

Confidence threshold (cross-fitted; fold 0 / fold 1): haiku 0.8 / 0.7; ondevice 0.0 / 0.95

### What each part of the hybrid does (against the hindsight labels)

| model | variant | error | coverage | confidently wrong | open-ended shown |
|---|---|---|---|---|---|
| haiku | as planned | 0.244 | 49% | 25% | 0% |
| haiku | no plan split | 0.253 | 35% | 33% | 0% |
| haiku | no hard rules | 0.208 | 49% | 18% | 0% |
| haiku | without 0.9 cap | 0.248 | 49% | 25% | 0% |
| haiku | without 0.4 cap | 0.213 | 49% | 20% | 0% |
| haiku | without fail rule | 0.237 | 49% | 24% | 0% |
| haiku | no threshold | 0.261 | 94% | 29% | 60% |
| ondevice | as planned | 0.335 | 88% | 43% | 60% |
| ondevice | no plan split | 0.331 | 87% | 42% | 60% |
| ondevice | no hard rules | 0.286 | 88% | 36% | 60% |
| ondevice | without 0.9 cap | 0.340 | 88% | 45% | 60% |
| ondevice | without 0.4 cap | 0.288 | 88% | 33% | 60% |
| ondevice | without fail rule | 0.334 | 88% | 43% | 60% |
| ondevice | no threshold | 0.330 | 100% | 42% | 100% |

| model | bar basis | n | error | confidently wrong |
|---|---|---|---|---|
| haiku | checklist | 7 | 0.324 | 43% |
| haiku | plan | 28 | 0.180 | 11% |
| haiku | read | 20 | 0.305 | 40% |
| ondevice | checklist | 7 | 0.324 | 43% |
| ondevice | plan | 11 | 0.282 | 36% |
| ondevice | read | 81 | 0.343 | 44% |

### Latency and cost

| model | answered | median s | p90 s | per call | total | mean tokens in / out |
|---|---|---|---|---|---|---|
| haiku | 117 of 117 | 8.0 | 10.0 | $0.0217 | $2.54 | 36338 / 879 |
| ondevice | 117 of 117 | 8.4 | 15.3 | $0.0000 | $0.00 | – / – |

haiku: kinds {'bounded': 107, 'open_ended': 10}; bars by basis {'checklist': 7, 'plan': 28, 'read': 20, 'low_confidence': 53, 'open': 9, 'none': 0}.
ondevice: kinds {'bounded': 117, 'open_ended': 0}; bars by basis {'checklist': 7, 'plan': 11, 'read': 84, 'low_confidence': 15, 'open': 0, 'none': 0}.

### Gate (model hybrids, against the hindsight labels)

| candidate | error ≤ 0.15 | confidently wrong ≤ 10% | open-ended shown ≤ 10% | coverage ≥ 30% | beats best rule on GPT's 24 grades | passes |
|---|---|---|---|---|---|---|
| haiku hybrid | no | no | yes | yes | yes (0.115 vs const 0.283, n=18) | no |
| ondevice hybrid | no | no | no | yes | no (0.298 vs stage 0.264, n=18) | no |

---

## Confirmation round (pre-registered, 64 new moments)

Checkpoints 64: bounded mid-work 48 (from 20 objectives; 6 bounded openings kept apart), open-ended mid-work 10 (from 8 objectives; 8 of them openings); 20 sessions, 4 projects. Haiku answered 64, missing 0.

| candidate | error | error (adjudicated) | coverage | confidently wrong | open-ended shown |
|---|---|---|---|---|---|
| haiku-working | 0.169 | 0.156 | 94% (45/48) | 16% | 20% (2/10) |
| rule: const | 0.248 | 0.242 | 100% (48/48) | 25% | 100% (10/10) |
| rule: stage | 0.168 | 0.153 | 100% (48/48) | 15% | 100% (10/10) |
| rule: planfile | 0.195 | 0.181 | 100% (48/48) | 25% | 100% (10/10) |
| rule: checklist | – | – | 0% (0/48) | – | 0% (0/10) |

| gate | error <= 0.15 | wrong <= 10% | coverage >= 30% | open-ended shown <= 10%, n >= 15 | GPT subset | passes |
|---|---|---|---|---|---|---|
| haiku-working | NO | NO | yes | NO | pending | NO |

Secondary: with bounded openings error 0.164, coverage 87%; open-ended shown without openings 50% (1/2).
By moment (haiku-working): plan_approved n=4 err 0.000 cov 75%; first_edit n=17 err 0.188 cov 94%; check_after_edits n=16 err 0.144 cov 100%; new_prompt n=11 err 0.230 cov 91%
Haiku: 64 calls, $0.0212 per call, $1.35 total, median 7.5s.
Spend this round: {"tuning (haiku, Stage A)": 1.4683, "screening (opus)": 0.269, "labels (opus)": 2.9207, "haiku-working (new sample)": 1.3537, "total": 6.0117}
