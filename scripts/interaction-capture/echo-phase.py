"""Compare the first visible glyph only on trials with matched actual input phase and observed ticks."""
import argparse
from bisect import bisect_left, bisect_right
import json
from pathlib import Path
from statistics import median

TOLERANCE = 0.0008


def nearby(values, x):
    right = bisect_left(values, x)
    choices = range(max(0, right - 1), min(len(values), right + 1))
    return min(choices, key=lambda i: abs(values[i] - x))


def key_targets(report):
    records = {}
    for key in report['samples']:
        phase = key.get('displayPhase')
        if phase is None:
            continue
        ticks = sorted({s[k] for s in report['observedDisplayTicks'] for k in ['timestamp', 'targetTimestamp']})
        # Adjacent links sometimes give the same target with floating-point rounding.
        ticks = [t for i, t in enumerate(ticks) if i == 0 or t - ticks[i - 1] > 0.0004]
        key_at = key['keyAt']
        intended = phase['intendedTarget']
        interval = phase['referenceTick']['targetTimestamp'] - phase['referenceTick']['timestamp']
        if not ticks or interval <= 0:
            continue
        first = bisect_right(ticks, key_at)
        data = {'keyAt': key_at, 'intendedTarget': intended, 'intervalMs': 1000 * interval,
                'requestedFractionBeforeTarget': phase['requestedFractionBeforeTarget']}
        records[key['marker']] = data
        if first >= len(ticks) or abs(intended - ticks[first]) > TOLERANCE:
            data['unresolved'] = 'Intended refresh has no matching observed display tick.'
            continue
        target = ticks[first]
        data['actualTarget'] = target
        data['beforeTargetMs'] = 1000 * (target - key_at)
        for name, field in [('drawable', 'presentedAt'), ('windowPixels', 'firstPixelAt')]:
            time = key.get(field)
            if time is None:
                continue
            observed = {'at': time, 'keyToObservedMs': (time - key_at) * 1000}
            data[name] = observed
            index = nearby(ticks, time)
            observed['offsetFromNearestTickMs'] = 1000 * (time - ticks[index])
            if index < first or abs(ticks[index] - time) > TOLERANCE:
                observed['unresolved'] = 'Visible timestamp could not be aligned to a measured pane refresh.'
                continue
            distances = [b - a for a, b in zip(ticks[first:index], ticks[first+1:index+1])]
            if any(abs(d - interval) > max(.001, interval*.12) for d in distances):
                observed['unresolved'] = 'The display link skipped or changed its cadence.'
                continue
            if name == 'windowPixels':
                last_negative = key.get('previousPixelSampleAt')
                if last_negative is None or last_negative > time:
                    observed['unresolved'] = 'Missing the last glyph-negative camera observation.'
                    continue
                observed['negativeToPositiveMs'] = 1000 * (time - last_negative)
                lower = max(last_negative, key_at)
                # Key input after the preceding refresh or a glyph-negative frame at that
                # preceding refresh rules out an earlier visible echo. Otherwise keep the bound.
                if index > 0 and lower < ticks[index-1] - TOLERANCE:
                    observed['unresolved'] = 'The glyph could first have appeared in an unsampled refresh.'
                    continue
            observed['refreshesAfterUpcomingTarget'] = index - first
    return records


def compare(folder):
    pairs = []
    for b in sorted(folder.glob('pair-*-baseline.json')):
        n = b.name.split('-')[1]
        candidate = folder/f'pair-{n}-candidate.json'
        if not candidate.exists():
            continue
        sides = {side:key_targets(json.loads(path.read_text())) for side,path in [('baseline', b),('candidate',candidate)]}
        keys = []
        for letter in sides['baseline'].keys() & sides['candidate'].keys():
            before, after = sides['baseline'][letter], sides['candidate'][letter]
            item = {'marker': letter, 'baseline': before, 'candidate': after}
            if 'beforeTargetMs' in before and 'beforeTargetMs' in after:
                offset = after['beforeTargetMs'] - before['beforeTargetMs']
                item['actualPhaseDifferenceMs'] = offset
                item['phaseMatched'] = (abs(offset) <= TOLERANCE * 1000 and
                    before['requestedFractionBeforeTarget'] == after['requestedFractionBeforeTarget'] and
                    abs(before['intervalMs'] - after['intervalMs']) <= TOLERANCE * 1000)
                if item['phaseMatched']:
                    for method in ['drawable','windowPixels']:
                        field = 'refreshesAfterUpcomingTarget'
                        a, c = before.get(method,{}).get(field), after.get(method,{}).get(field)
                        if a is not None and c is not None:
                            item[method+'AdditionalRefreshes'] = c - a
            keys.append(item)
        pairs.append({'pair':int(n),'keys':sorted(keys,key=lambda k:k['marker'])})
    matched = [k for p in pairs for k in p['keys'] if k.get('phaseMatched')]
    summary = {'inputPhaseToleranceMs':TOLERANCE*1000,'matchedPhases':len(matched),
               'totalKeys':sum(len(p['keys']) for p in pairs),'pairs':pairs}
    for method in ['drawable','windowPixels']:
        deltas = [k[method+'AdditionalRefreshes'] for k in matched if method+'AdditionalRefreshes' in k]
        summary[method] = {'resolvedPairs':len(deltas),'sameRefresh':deltas.count(0),
            'candidateEarlier':sum(i<0 for i in deltas),'candidateLater':sum(i>0 for i in deltas),
            'maximumAdditionalRefreshes':max(deltas,default=None)}
    return summary


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    args=parser.parse_args()
    result=compare(args.directory)
    (args.directory/'phase-summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='pairs'}))
