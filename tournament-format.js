/* tournament-format.js — shared by index.html (members) and admin.html.
 *
 * "Groups + Knockout" (format: 'groups_ko') for one-day events like a 3x3
 * league: teams are drawn into groups, play a round robin inside their
 * group, the top N per group go to a knockout bracket.
 *
 * Everything here is pure (no DOM, no network) so both apps render the same
 * schedule, standings and bracket, and it can be tested in Node.
 *
 * Match shape (stored in tournaments.matches):
 *   { round:'gA-1', stage:'group'|'r16'|'qf'|'sf'|'3rd'|'final', group:'A'|null,
 *     label, court, wave, date, time, teamA, teamB, srcA, srcB, manual,
 *     scoreA, scoreB, winner:'A'|'B'|null, stats:[] }
 * srcA/srcB on knockout games: 'A1' = Group A 1st place, 'W:qf1' = winner of
 * qf1, 'L:sf1' = loser of sf1. A game with manual:true keeps whatever teams an
 * admin set by hand.
 */
(function (root) {
  'use strict';

  const FORMAT = 'groups_ko';

  const DEFAULTS = {
    roster_size: 4,          // players per team (incl. captain)
    group_size: 4,           // teams per group
    advance: 2,              // teams per group that reach the knockout
    courts: 2,               // games running at the same time
    court_names: ['Court A', 'Court B'],
    start_time: '08:00',     // 24h HH:MM on start_date
    slot_minutes: 12,        // game + changeover
    ko_break_minutes: 0,     // pause between groups and knockout
    final_minutes: 20,       // championship slot (stop clock)
    third_place: true,
    team_fee: 0,             // ₱ per team
    open_registration: true, // any member can register a team
    pay_before_slot: true,   // slot is secured only after payment is verified
  };

  const STAGE_LABEL = { r16: 'Round of 16', qf: 'Quarterfinal', sf: 'Semifinal', '3rd': '3rd Place', final: 'Championship' };

  function isGroupsKO(t) { return !!t && t.format === FORMAT; }

  function cfg(t) {
    const c = Object.assign({}, DEFAULTS, (t && t.config) || {});
    c.roster_size = clampInt(c.roster_size, 1, 20, DEFAULTS.roster_size);
    c.group_size = clampInt(c.group_size, 3, 8, DEFAULTS.group_size);
    c.advance = clampInt(c.advance, 1, 2, DEFAULTS.advance);
    c.courts = clampInt(c.courts, 1, 8, DEFAULTS.courts);
    c.slot_minutes = clampInt(c.slot_minutes, 5, 120, DEFAULTS.slot_minutes);
    c.ko_break_minutes = clampInt(c.ko_break_minutes, 0, 240, 0);
    c.final_minutes = clampInt(c.final_minutes, 5, 120, DEFAULTS.final_minutes);
    c.team_fee = Math.max(0, Number(c.team_fee) || 0);
    if (!Array.isArray(c.court_names)) c.court_names = [];
    c.court_names = Array.from({ length: c.courts }, (_, i) => (c.court_names[i] || '').trim() || ('Court ' + String.fromCharCode(65 + i)));
    if (!/^\d{1,2}:\d{2}$/.test(c.start_time || '')) c.start_time = DEFAULTS.start_time;
    return c;
  }

  function clampInt(v, lo, hi, dflt) {
    const n = parseInt(v, 10);
    if (isNaN(n)) return dflt;
    return Math.min(hi, Math.max(lo, n));
  }

  function groupLetters(n) { return Array.from({ length: n }, (_, i) => String.fromCharCode(65 + i)); }

  function groupCount(teamCount, groupSize) { return Math.max(1, Math.ceil(teamCount / groupSize)); }

  // ── time helpers ────────────────────────────────────────────────
  function addMinutes(hhmm, mins) {
    const [h, m] = String(hhmm).split(':').map(Number);
    const total = ((h * 60 + m + mins) % 1440 + 1440) % 1440;
    return String(Math.floor(total / 60)).padStart(2, '0') + ':' + String(total % 60).padStart(2, '0');
  }
  function fmtTime(hhmm) {
    if (!hhmm || !/^\d{1,2}:\d{2}$/.test(hhmm)) return hhmm || '';
    let [h, m] = hhmm.split(':').map(Number);
    const ap = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return h + ':' + String(m).padStart(2, '0') + ' ' + ap;
  }

  // ── group draw ──────────────────────────────────────────────────
  // 'seeded' snakes teams in their current order (A,B,C,D,D,C,B,A,...) so the
  // first teams listed are spread across groups; 'random' shuffles first.
  function assignGroups(teams, groupSize, mode, rand) {
    const list = teams.map(t => Object.assign({}, t));
    if (mode === 'random') {
      const r = rand || Math.random;
      for (let i = list.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [list[i], list[j]] = [list[j], list[i]]; }
    }
    const g = groupCount(list.length, groupSize);
    const letters = groupLetters(g);
    list.forEach((t, i) => {
      const lap = Math.floor(i / g), pos = i % g;
      t.group = letters[lap % 2 === 0 ? pos : g - 1 - pos];
    });
    // keep the teams' original order in the array; only .group changes
    const byId = new Map(list.map(t => [t.id, t.group]));
    return teams.map(t => Object.assign({}, t, { group: byId.get(t.id) }));
  }

  // Round robin "matchdays" (circle method): every team plays at most once
  // per matchday. Returns [[ [i,j], ... ], ...] of indexes into `ids`.
  function rrMatchdays(n) {
    const idx = Array.from({ length: n }, (_, i) => i);
    if (n % 2) idx.push(-1); // bye
    const m = idx.length, days = [];
    for (let d = 0; d < m - 1; d++) {
      const pairs = [];
      for (let k = 0; k < m / 2; k++) {
        const a = idx[k], b = idx[m - 1 - k];
        if (a !== -1 && b !== -1) pairs.push(a < b ? [a, b] : [b, a]);
      }
      days.push(pairs);
      idx.splice(1, 0, idx.pop()); // rotate all but the first
    }
    return days;
  }

  // ── knockout plan ───────────────────────────────────────────────
  // Returns { error } or { games:[{round,stage,label,srcA,srcB}] } in play order.
  function koPlan(letters, advance, thirdPlace) {
    const G = letters.length;
    const N = G * advance;
    if (N < 2) return { error: 'At least two teams must reach the knockout.' };
    if ((N & (N - 1)) !== 0) return { error: `${G} groups × top ${advance} = ${N} teams — the knockout needs 2, 4, 8 or 16 teams. Change the group size or how many advance.` };
    if (N > 16) return { error: 'Knockouts larger than 16 teams aren\'t supported.' };

    // First-round slots in bracket order (consecutive pairs meet).
    let first = [];
    if (advance === 1) {
      for (let i = 0; i < G; i += 2) first.push([letters[i] + '1', letters[i + 1] + '1']);
    } else {
      // Pair groups (A,B),(C,D)...; top half X1 v Y2, bottom half Y1 v X2, so
      // teams from the same group can only meet again in the final.
      const top = [], bottom = [];
      for (let i = 0; i < G; i += 2) {
        const X = letters[i], Y = letters[i + 1];
        top.push([X + '1', Y + '2']);
        bottom.push([Y + '1', X + '2']);
      }
      first = top.concat(bottom);
    }

    const stageFor = teams => teams === 16 ? 'r16' : teams === 8 ? 'qf' : teams === 4 ? 'sf' : 'final';
    const games = [];
    let round = first.map(p => ({ srcA: p[0], srcB: p[1] }));
    let teams = N;
    let semis = null;
    while (round.length) {
      const stage = stageFor(teams);
      const ids = round.map((g, i) => stage === 'final' ? 'final' : stage + (i + 1));
      round.forEach((g, i) => games.push({
        round: ids[i], stage,
        label: stage === 'final' ? STAGE_LABEL.final : STAGE_LABEL[stage] + ' ' + (i + 1),
        srcA: g.srcA, srcB: g.srcB,
      }));
      if (stage === 'sf') semis = ids;
      if (round.length === 1) break;
      const next = [];
      for (let i = 0; i < ids.length; i += 2) next.push({ srcA: 'W:' + ids[i], srcB: 'W:' + ids[i + 1] });
      round = next;
      teams = teams / 2;
    }
    if (thirdPlace && semis) {
      // 3rd place is played just before the final.
      const fi = games.findIndex(g => g.stage === 'final');
      games.splice(fi, 0, { round: '3rd', stage: '3rd', label: STAGE_LABEL['3rd'], srcA: 'L:' + semis[0], srcB: 'L:' + semis[1] });
    }
    return { games };
  }

  // Human-readable source: 'A1' -> 'Group A #1', 'W:qf1' -> 'Winner QF 1'
  function srcLabel(src) {
    if (!src) return 'TBD';
    const m = /^([A-Z])(\d)$/.exec(src);
    if (m) return 'Group ' + m[1] + ' #' + m[2];
    const k = /^([WL]):(\w+)$/.exec(src);
    if (k) {
      const r = k[2];
      const nice = r === 'final' ? 'Final' : r === '3rd' ? '3rd' : r.replace(/^(r16|qf|sf)(\d+)$/, (_, s, n) => ({ r16: 'R16', qf: 'QF', sf: 'SF' }[s] + ' ' + n));
      return (k[1] === 'W' ? 'Winner ' : 'Loser ') + nice;
    }
    return src;
  }

  // ── schedule ────────────────────────────────────────────────────
  // Builds every game with court + time. Teams must already have .group.
  function buildSchedule(t) {
    const c = cfg(t);
    const teams = Array.isArray(t.teams) ? t.teams : [];
    if (teams.length < 2) return { error: 'Add at least 2 teams first.' };
    if (teams.some(tm => !tm.group)) return { error: 'Draw the groups first.' };
    const letters = [...new Set(teams.map(tm => tm.group))].sort();
    const plan = koPlan(letters, c.advance, c.third_place);
    if (plan.error) return plan;

    // Group games, matchday by matchday, groups interleaved.
    const groupGames = [];
    const days = {};
    letters.forEach(L => {
      const ids = teams.filter(tm => tm.group === L).map(tm => tm.id);
      days[L] = rrMatchdays(ids.length).map(day => day.map(([i, j]) => [ids[i], ids[j]]));
    });
    const maxDays = Math.max(...letters.map(L => days[L].length));
    const counter = {};
    for (let d = 0; d < maxDays; d++) {
      letters.forEach(L => (days[L][d] || []).forEach(([a, b]) => {
        counter[L] = (counter[L] || 0) + 1;
        groupGames.push({ round: 'g' + L + '-' + counter[L], stage: 'group', group: L, label: 'Group ' + L + ' · Game ' + counter[L], teamA: a, teamB: b });
      }));
    }

    const out = [];
    let wave = 0, clock = 0; // minutes from start
    const place = (games, minutes) => {
      for (let i = 0; i < games.length; i += c.courts) {
        games.slice(i, i + c.courts).forEach((g, k) => out.push(Object.assign({
          group: null, teamA: null, teamB: null, srcA: null, srcB: null, manual: false,
          scoreA: null, scoreB: null, winner: null, stats: [],
        }, g, { court: c.court_names[k], wave, date: t.start_date || null, time: addMinutes(c.start_time, clock) })));
        wave++; clock += minutes;
      }
    };
    place(groupGames, c.slot_minutes);
    clock += c.ko_break_minutes;
    // Each knockout stage starts on a fresh wave; 3rd place and final get
    // their own slot each so everyone can watch.
    const stages = ['r16', 'qf', 'sf'];
    stages.forEach(s => { const gs = plan.games.filter(g => g.stage === s); if (gs.length) place(gs, c.slot_minutes); });
    const third = plan.games.filter(g => g.stage === '3rd');
    if (third.length) place(third, c.slot_minutes);
    place(plan.games.filter(g => g.stage === 'final'), c.final_minutes);

    return { matches: out, endTime: addMinutes(c.start_time, clock), totalMinutes: clock, waves: wave };
  }

  // Quick sizing for the admin form, before teams exist.
  function estimate(config, teamCount) {
    const c = cfg({ config });
    const G = groupCount(teamCount, c.group_size);
    const plan = koPlan(groupLetters(G), c.advance, c.third_place);
    const sizes = Array.from({ length: G }, (_, i) => Math.floor(teamCount / G) + (i < teamCount % G ? 1 : 0));
    const groupGames = sizes.reduce((s, n) => s + n * (n - 1) / 2, 0);
    if (plan.error) return { groups: G, groupGames, error: plan.error };
    const waves = n => Math.ceil(n / c.courts);
    const ko = s => plan.games.filter(g => g.stage === s).length;
    let minutes = waves(groupGames) * c.slot_minutes + c.ko_break_minutes;
    ['r16', 'qf', 'sf'].forEach(s => { minutes += waves(ko(s)) * c.slot_minutes; });
    if (ko('3rd')) minutes += c.slot_minutes;
    minutes += c.final_minutes;
    return {
      groups: G, groupGames, koGames: plan.games.length, totalGames: groupGames + plan.games.length,
      minGamesPerTeam: Math.min(...sizes) - 1, minutes, endTime: addMinutes(c.start_time, minutes),
    };
  }

  // ── results ─────────────────────────────────────────────────────
  function winnerId(m) { return !m || !m.winner ? null : m.winner === 'A' ? m.teamA : m.teamB; }
  function loserId(m) { return !m || !m.winner ? null : m.winner === 'A' ? m.teamB : m.teamA; }

  // Wins, then head-to-head among the tied teams, then point difference,
  // then points scored, then name.
  function groupStandings(t, letter) {
    const teams = (t.teams || []).filter(tm => tm.group === letter);
    const games = (t.matches || []).filter(m => m.stage === 'group' && m.group === letter);
    const row = id => ({ id, name: (teams.find(x => x.id === id) || {}).name || 'Team', played: 0, w: 0, l: 0, pf: 0, pa: 0, diff: 0 });
    const rows = new Map(teams.map(tm => [tm.id, row(tm.id)]));
    games.forEach(m => {
      if (!m.winner || !rows.has(m.teamA) || !rows.has(m.teamB)) return;
      const a = rows.get(m.teamA), b = rows.get(m.teamB);
      const sa = Number(m.scoreA) || 0, sb = Number(m.scoreB) || 0;
      a.played++; b.played++; a.pf += sa; a.pa += sb; b.pf += sb; b.pa += sa;
      if (m.winner === 'A') { a.w++; b.l++; } else { b.w++; a.l++; }
    });
    rows.forEach(r => { r.diff = r.pf - r.pa; });
    const h2hWins = (id, among) => games.filter(m => m.winner && among.has(m.teamA) && among.has(m.teamB) && winnerId(m) === id).length;
    const byWins = new Map();
    rows.forEach(r => { if (!byWins.has(r.w)) byWins.set(r.w, []); byWins.get(r.w).push(r); });
    const sorted = [];
    [...byWins.keys()].sort((x, y) => y - x).forEach(w => {
      const block = byWins.get(w);
      const among = new Set(block.map(r => r.id));
      block.forEach(r => { r.h2h = block.length > 1 ? h2hWins(r.id, among) : 0; });
      block.sort((x, y) => (y.h2h - x.h2h) || (y.diff - x.diff) || (y.pf - x.pf) || x.name.localeCompare(y.name));
      sorted.push(...block);
    });
    return sorted;
  }

  function groupLettersOf(t) { return [...new Set((t.teams || []).map(tm => tm.group).filter(Boolean))].sort(); }

  function groupComplete(t, letter) {
    const games = (t.matches || []).filter(m => m.stage === 'group' && m.group === letter);
    return games.length > 0 && games.every(m => !!m.winner);
  }

  // Resolves a knockout source to a team id, or null if not decided yet.
  function resolveSrc(t, src, standingsCache) {
    if (!src) return null;
    const g = /^([A-Z])(\d)$/.exec(src);
    if (g) {
      if (!groupComplete(t, g[1])) return null;
      const st = standingsCache[g[1]] || (standingsCache[g[1]] = groupStandings(t, g[1]));
      const r = st[Number(g[2]) - 1];
      return r ? r.id : null;
    }
    const k = /^([WL]):(\w+)$/.exec(src);
    if (k) {
      const m = (t.matches || []).find(x => x.round === k[2]);
      return k[1] === 'W' ? winnerId(m) : loserId(m);
    }
    return null;
  }

  // Fills knockout teams from finished groups/games. Leaves games that have a
  // result or were set by hand (manual:true) alone. Returns a new array and
  // whether anything changed.
  function resolveKO(t) {
    const cache = {};
    let changed = false;
    // Work in play order so later rounds see earlier winners.
    const matches = (t.matches || []).map(m => Object.assign({}, m));
    const view = Object.assign({}, t, { matches });
    matches.forEach(m => {
      if (m.stage === 'group' || m.manual || m.winner) return;
      const a = resolveSrc(view, m.srcA, cache), b = resolveSrc(view, m.srcB, cache);
      if (a !== m.teamA || b !== m.teamB) { m.teamA = a; m.teamB = b; changed = true; }
    });
    return { matches, changed };
  }

  // Sets a result; winner comes from the score unless it's tied (then the
  // caller must pass one). Returns { error } or { matches }.
  function applyResult(t, round, scoreA, scoreB, winnerOverride) {
    const matches = (t.matches || []).map(m => Object.assign({}, m));
    const m = matches.find(x => x.round === round);
    if (!m) return { error: 'Game not found.' };
    if (!m.teamA || !m.teamB) return { error: 'Both teams must be set before entering a score.' };
    const a = Number(scoreA), b = Number(scoreB);
    if (!Number.isFinite(a) || !Number.isFinite(b) || a < 0 || b < 0) return { error: 'Enter both scores.' };
    let w = a > b ? 'A' : b > a ? 'B' : (winnerOverride === 'A' || winnerOverride === 'B' ? winnerOverride : null);
    if (!w) return { error: 'Scores are tied — pick who won in overtime.' };
    m.scoreA = a; m.scoreB = b; m.winner = w;
    return resolveKO(Object.assign({}, t, { matches }));
  }

  function clearResult(t, round) {
    const matches = (t.matches || []).map(m => Object.assign({}, m));
    const m = matches.find(x => x.round === round);
    if (!m) return { error: 'Game not found.' };
    m.scoreA = null; m.scoreB = null; m.winner = null;
    // Downstream games that haven't been played yet are re-resolved.
    return resolveKO(Object.assign({}, t, { matches }));
  }

  function teamFee(t) {
    if (isGroupsKO(t)) return cfg(t).team_fee;
    const pool = (t.fee_breakdown || []).reduce((s, x) => s + (Number(x.amount) || 0), 0);
    const n = (t.teams || []).length;
    return n > 1 ? Math.round(pool / n) : pool;
  }

  function matchLabel(m) {
    if (!m) return '';
    if (m.label) return m.label;
    return ({ rr1: 'Game 1', rr2: 'Game 2', rr3: 'Game 3', rr4: 'Game 4', rr5: 'Game 5', rr6: 'Game 6', '3rd': '3rd Place Match', final: 'Championship' })[m.round] || m.round;
  }

  // Summary text for the Info tab.
  function describe(t) {
    const c = cfg(t);
    const n = (t.teams || []).length || t.max_teams || 0;
    const G = groupCount(n, c.group_size);
    return `${n} teams of ${c.roster_size} · ${G} groups of ${c.group_size} · top ${c.advance} per group advance to the knockout`;
  }

  const TF = {
    FORMAT, DEFAULTS, STAGE_LABEL, isGroupsKO, cfg, groupLetters, groupCount, addMinutes, fmtTime,
    assignGroups, rrMatchdays, koPlan, srcLabel, buildSchedule, estimate, winnerId, loserId,
    groupStandings, groupLettersOf, groupComplete, resolveKO, applyResult, clearResult, teamFee, matchLabel, describe,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = TF;
  else root.TF = TF;
})(typeof window !== 'undefined' ? window : this);
