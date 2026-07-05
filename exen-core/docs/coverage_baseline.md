# Post-fix static coverage baseline — 51 gamelets (samples/)

> **2026-07-03 update 2** — opcode column is now EMPTY corpus-wide (0/51
> games flag any unbound opcode). Two static-walker bugs were the entire
> cause of the earlier 70-byte "unknown opcode" spread: (1) abstract
> methods (ACC_ABSTRACT 0x400, body_off=0) were walked from the class
> header; (2) LOOKUPSWITCH_W (0xAB) was stepped with the 0xCC layout
> (u16 pairs) instead of its 4-byte-aligned u32-key layout, drifting the
> walker into the jump table. All 9 investigated "opcodes" (0x0b 0x13
> 0x20 0x25 0x6e 0xb4 0xc4 0xc8 0xfc) map to the empty canonical trap
> sub_4102CF — zero real missing opcodes. Fixes in coverage_audit.zig +
> disasm.zig + disasm_method.zig + scan_callers.zig. The VM was always
> correct (0 UNIMPL halts). ONLY remaining native gap corpus-wide: the
> Sms family (78, 93, 94, 97-100).

> **2026-07-03 batch update** (Runtime 175-177, Catalog 178-184, FX
> 103-108 full kernels, Matrix3D 123-128, Vector3D 129-136 all ported):
> **catalog and wallbreaker are now fully clean**; remaining unbound
> natives corpus-wide are ONLY the Sms family (78, 93, 94, 97-100),
> AnimFlash (56-64 partial), and RayCast (137-146). MidtownMadness3's
> loading gate unblocked by Runtime.getTickCount (menu now renders).
> The per-game table below predates the batch for those idx ranges.

Generated 2026-07-02 by zig-out/bin/coverage_audit (post NEWARRAY/CHECKCAST/INSTANCEOF walker fix). Raw per-game outputs: <game>.txt in this directory; parser: parse.py. All 51 runs exited 0. UNRESOLVED INVOKES ignored.

| Game | Unbound opcodes (byte×sites) | Unbound natives (idx×sites) | Triage |
|---|---|---|---|
| 007Ice-Racer | — | 78×2, 93×6, 94×6, 97×1, 98×1, 100×1 | natives-only |
| AgeOfEmpiresMobile | 0x6e×1 | 78×2, 93×6, 94×7, 97×1, 98×1 | opcodes! |
| Arthur&LesPirates | — | 93×3, 94×4, 97×1, 98×1 | natives-only |
| BanjoKazooie | — | 93×3, 97×1, 98×1 | natives-only |
| BombJack | — | 78×4, 93×4, 94×6, 97×1, 98×1 | natives-only |
| BombSquad | — | 78×1, 93×3, 94×10, 97×1, 98×1 | natives-only |
| catalog | — | 178×1, 179×1, 181×1, 182×1, 183×1 | natives-only |
| Charmed | — | 78×1, 93×7, 94×8, 97×1, 98×1, 100×1 | natives-only |
| Crash Bandicoot | — | 93×2, 100×1 | natives-only |
| crash_bandicoot | — | 93×2, 100×1 | natives-only |
| CrazyCobra2 | — | 93×3, 94×4, 97×1, 98×1 | natives-only |
| download1 | 0x27×6, 0x38×4, 0x18×4, 0x0b×4, 0x73×32, 0x63×17, 0x6f×18, 0x67×4, 0x43×4, 0x72×20, 0x0f×4, 0x48×4, 0x0c×4, 0x6e×8, 0x90×1, 0x3c×1, 0x28×2, 0xc9×1, 0x3e×1, 0x30×1 | 57×1, 104×1, 106×1, 108×1, 124×1, 125×1, 126×1, 127×2, 128×1, 132×1, 137×1, 138×3 | opcodes! |
| EagleSquadron | — | 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| FighterPilotEvolved | — | 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| Flynn | — | 93×3, 94×4, 97×1, 98×1 | natives-only |
| FootballFans | — | 78×1, 93×4, 94×6, 97×1, 98×1 | natives-only |
| GhostHunter | — | 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| IFPingPong | — | 78×1, 93×5, 94×10, 97×1, 98×1 | natives-only |
| IFRacing | — | 78×1, 93×4, 94×6, 97×1, 98×1, 100×2 | natives-only |
| IFRacing2 | — | 62×13, 78×3, 93×31, 94×21, 97×2, 98×2, 99×1 | natives-only |
| IFSkiExtreme | — | 93×4, 97×1, 98×1, 99×1 | natives-only |
| IFSkiJumping | — | 93×4, 97×1, 98×1, 99×1 | natives-only |
| IFSudoku | — | 93×4, 97×1, 98×1, 99×1 | natives-only |
| JungleRun | — | 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| MalibuRide2 | — | 78×4, 93×10, 94×10, 97×1, 98×1 | natives-only |
| MidtownMadness3 | 0x13×1, 0xb4×1 | 78×1, 93×30, 94×13, 97×1, 98×1, 99×1, 175×19, 177×9 | opcodes! |
| MonkeyBusiness | — | 93×4, 97×1, 98×1, 99×1 | natives-only |
| MotoGp | 0x27×4, 0x77×2, 0xfc×2, 0x44×2, 0x38×2, 0x8f×6, 0x15×2, 0x0b×2, 0x40×2, 0x42×12, 0xd3×2, 0x3e×4, 0x76×2, 0xff×2, 0x0e×2, 0xba×2, 0x96×2, 0x21×2 | 78×1, 93×3, 94×7, 97×1, 98×1, 100×1 | opcodes! |
| MutantAlert | 0xc4×1, 0x20×1, 0x0b×1, 0xfc×3, 0xc8×1 | 78×1, 93×5, 94×6, 97×1, 98×1, 137×1, 138×1, 141×2, 142×14, 143×7, 144×6 | opcodes! |
| Panko | — | 93×2 | natives-only |
| Pikubi | 0x27×2, 0x98×2, 0xfc×2, 0xfb×2, 0xd3×6, 0x3d×2, 0x90×8, 0x76×2, 0x0d×4, 0x42×10, 0xb7×2, 0x41×2, 0x63×2, 0xc8×2, 0x8f×2, 0x0b×2, 0x0c×2, 0xcf×2 | 78×1, 93×3, 94×7, 97×1, 98×1 | opcodes! |
| Pikubi2 | 0xc4×1, 0x25×1 | 93×4, 97×1, 98×1, 99×1, 180×2 | opcodes! |
| Reversi | — | 78×1, 93×3, 94×10, 97×1, 98×1 | natives-only |
| SexyBreakerBikini | — | 78×1, 93×6, 94×10, 97×1, 98×1 | natives-only |
| SexyManga | — | 78×1, 93×6, 94×10, 97×1, 98×1 | natives-only |
| SexyVideoPoker | — | 78×1, 93×6, 94×10, 97×1, 98×1 | natives-only |
| ShadoFighter | — | 78×1, 93×2, 94×3, 97×1, 98×1, 105×1 | natives-only |
| SouthPark | — | 78×3, 93×6, 94×11, 97×2, 98×1, 100×1 | natives-only |
| SphereMadness | — | 62×5, 64×2, 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| SphereMadness2 | — | 62×5, 64×2, 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| Spyro | — | 56×1, 62×7, 63×6, 64×4, 100×1, 108×1 | natives-only |
| StarWars3 | — | 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| terminator | — | 93×2, 100×1 | natives-only |
| TheTerminator | — | 78×1, 93×5, 94×10, 97×1, 98×1, 100×1 | natives-only |
| TombRaider | — | 93×2, 97×1, 98×1 | natives-only |
| TombRaider2 | — | 93×2, 97×1, 98×1 | natives-only |
| TombRaider3 | — | 93×2, 97×1, 98×1 | natives-only |
| TourDeFrance | — | 78×1, 93×6, 94×10, 97×1, 98×1, 100×1 | natives-only |
| wallbreaker | — | 104×1 | natives-only |
| Worms | — | 60×2, 78×1, 93×3, 94×7, 97×1, 98×1 | natives-only |
| XMasTales | — | 93×3, 94×4, 97×1, 98×1 | natives-only |

== OPCODE ROLLUP ==
| Byte | #games | total sites | games |
|---|---|---|---|
| 0x0b | 4 | 9 | MotoGp, MutantAlert, Pikubi, download1 |
| 0x27 | 3 | 12 | MotoGp, Pikubi, download1 |
| 0xfc | 3 | 7 | MotoGp, MutantAlert, Pikubi |
| 0x42 | 2 | 22 | MotoGp, Pikubi |
| 0x63 | 2 | 19 | Pikubi, download1 |
| 0x6e | 2 | 9 | AgeOfEmpiresMobile, download1 |
| 0x90 | 2 | 9 | Pikubi, download1 |
| 0x8f | 2 | 8 | MotoGp, Pikubi |
| 0xd3 | 2 | 8 | MotoGp, Pikubi |
| 0x38 | 2 | 6 | MotoGp, download1 |
| 0x0c | 2 | 6 | Pikubi, download1 |
| 0x3e | 2 | 5 | MotoGp, download1 |
| 0x76 | 2 | 4 | MotoGp, Pikubi |
| 0xc8 | 2 | 3 | MutantAlert, Pikubi |
| 0xc4 | 2 | 2 | MutantAlert, Pikubi2 |
| 0x73 | 1 | 32 | download1 |
| 0x72 | 1 | 20 | download1 |
| 0x6f | 1 | 18 | download1 |
| 0x0d | 1 | 4 | Pikubi |
| 0x18 | 1 | 4 | download1 |
| 0x67 | 1 | 4 | download1 |
| 0x43 | 1 | 4 | download1 |
| 0x0f | 1 | 4 | download1 |
| 0x48 | 1 | 4 | download1 |
| 0x77 | 1 | 2 | MotoGp |
| 0x44 | 1 | 2 | MotoGp |
| 0x15 | 1 | 2 | MotoGp |
| 0x40 | 1 | 2 | MotoGp |
| 0xff | 1 | 2 | MotoGp |
| 0x0e | 1 | 2 | MotoGp |
| 0xba | 1 | 2 | MotoGp |
| 0x96 | 1 | 2 | MotoGp |
| 0x21 | 1 | 2 | MotoGp |
| 0x98 | 1 | 2 | Pikubi |
| 0xfb | 1 | 2 | Pikubi |
| 0x3d | 1 | 2 | Pikubi |
| 0xb7 | 1 | 2 | Pikubi |
| 0x41 | 1 | 2 | Pikubi |
| 0xcf | 1 | 2 | Pikubi |
| 0x28 | 1 | 2 | download1 |
| 0x13 | 1 | 1 | MidtownMadness3 |
| 0xb4 | 1 | 1 | MidtownMadness3 |
| 0x20 | 1 | 1 | MutantAlert |
| 0x25 | 1 | 1 | Pikubi2 |
| 0x3c | 1 | 1 | download1 |
| 0xc9 | 1 | 1 | download1 |
| 0x30 | 1 | 1 | download1 |

== NATIVE ROLLUP ==
| idx | name | sub | #games | total call sites | games |
|---|---|---|---|---|---|
| 93 | Sms.readBits | sub_429AC0 | 47 | 234 | 007Ice-Racer, AgeOfEmpiresMobile, Arthur&LesPirates, BanjoKazooie, BombJack, BombSquad, Charmed, Crash Bandicoot, CrazyCobra2, EagleSquadron, FighterPilotEvolved, Flynn, FootballFans, GhostHunter, IFPingPong, IFRacing, IFRacing2, IFSkiExtreme, IFSkiJumping, IFSudoku, JungleRun, MalibuRide2, MidtownMadness3, MonkeyBusiness, MotoGp, MutantAlert, Panko, Pikubi, Pikubi2, Reversi, SexyBreakerBikini, SexyManga, SexyVideoPoker, ShadoFighter, SouthPark, SphereMadness, SphereMadness2, StarWars3, TheTerminator, TombRaider, TombRaider2, TombRaider3, TourDeFrance, Worms, XMasTales, crash_bandicoot, terminator |
| 97 | Sms.getIdBlock | sub_429CB0 | 43 | 45 | 007Ice-Racer, AgeOfEmpiresMobile, Arthur&LesPirates, BanjoKazooie, BombJack, BombSquad, Charmed, CrazyCobra2, EagleSquadron, FighterPilotEvolved, Flynn, FootballFans, GhostHunter, IFPingPong, IFRacing, IFRacing2, IFSkiExtreme, IFSkiJumping, IFSudoku, JungleRun, MalibuRide2, MidtownMadness3, MonkeyBusiness, MotoGp, MutantAlert, Pikubi, Pikubi2, Reversi, SexyBreakerBikini, SexyManga, SexyVideoPoker, ShadoFighter, SouthPark, SphereMadness, SphereMadness2, StarWars3, TheTerminator, TombRaider, TombRaider2, TombRaider3, TourDeFrance, Worms, XMasTales |
| 98 | Sms.getLengthBlock | sub_429D2A | 43 | 44 | 007Ice-Racer, AgeOfEmpiresMobile, Arthur&LesPirates, BanjoKazooie, BombJack, BombSquad, Charmed, CrazyCobra2, EagleSquadron, FighterPilotEvolved, Flynn, FootballFans, GhostHunter, IFPingPong, IFRacing, IFRacing2, IFSkiExtreme, IFSkiJumping, IFSudoku, JungleRun, MalibuRide2, MidtownMadness3, MonkeyBusiness, MotoGp, MutantAlert, Pikubi, Pikubi2, Reversi, SexyBreakerBikini, SexyManga, SexyVideoPoker, ShadoFighter, SouthPark, SphereMadness, SphereMadness2, StarWars3, TheTerminator, TombRaider, TombRaider2, TombRaider3, TourDeFrance, Worms, XMasTales |
| 94 | Sms.writeBits | sub_429B0A | 34 | 269 | 007Ice-Racer, AgeOfEmpiresMobile, Arthur&LesPirates, BombJack, BombSquad, Charmed, CrazyCobra2, EagleSquadron, FighterPilotEvolved, Flynn, FootballFans, GhostHunter, IFPingPong, IFRacing, IFRacing2, JungleRun, MalibuRide2, MidtownMadness3, MotoGp, MutantAlert, Pikubi, Reversi, SexyBreakerBikini, SexyManga, SexyVideoPoker, ShadoFighter, SouthPark, SphereMadness, SphereMadness2, StarWars3, TheTerminator, TourDeFrance, Worms, XMasTales |
| 78 | Gamelet.sendSms | sub_4250C7 | 30 | 42 | 007Ice-Racer, AgeOfEmpiresMobile, BombJack, BombSquad, Charmed, EagleSquadron, FighterPilotEvolved, FootballFans, GhostHunter, IFPingPong, IFRacing, IFRacing2, JungleRun, MalibuRide2, MidtownMadness3, MotoGp, MutantAlert, Pikubi, Reversi, SexyBreakerBikini, SexyManga, SexyVideoPoker, ShadoFighter, SouthPark, SphereMadness, SphereMadness2, StarWars3, TheTerminator, TourDeFrance, Worms |
| 100 | Sms.getPrice | sub_429E0A | 11 | 12 | 007Ice-Racer, Charmed, Crash Bandicoot, IFRacing, MotoGp, SouthPark, Spyro, TheTerminator, TourDeFrance, crash_bandicoot, terminator |
| 99 | Sms.skipBits | sub_429D86 | 7 | 7 | IFRacing2, IFSkiExtreme, IFSkiJumping, IFSudoku, MidtownMadness3, MonkeyBusiness, Pikubi2 |
| 62 | AnimFlash.getRawFrames | sub_42490E | 4 | 30 | IFRacing2, SphereMadness, SphereMadness2, Spyro |
| 64 | AnimFlash.getHeight | sub_42492A | 3 | 8 | SphereMadness, SphereMadness2, Spyro |
| 104 | FX.doMosaic | sub_424BFD | 2 | 2 | download1, wallbreaker |
| 108 | FX.doShutterHorizontal | sub_424ED2 | 2 | 2 | Spyro, download1 |
| 137 | RayCast.draw | sub_4284C9 | 2 | 2 | MutantAlert, download1 |
| 138 | RayCast.isThereAWall | sub_428683 | 2 | 4 | MutantAlert, download1 |
| 56 | AnimFlash.delete | sub_4248CA | 1 | 1 | Spyro |
| 57 | AnimFlash.setFrame | sub_4248D2 | 1 | 1 | download1 |
| 60 | AnimFlash.setPosition | sub_4248FE | 1 | 2 | Worms |
| 63 | AnimFlash.getWidth | sub_424916 | 1 | 6 | Spyro |
| 105 | FX.doShiftHorizontal | sub_424C84 | 1 | 1 | ShadoFighter |
| 106 | FX.doShiftVertical | sub_424D62 | 1 | 1 | download1 |
| 124 | Matrix3D.rotX | sub_426B89 | 1 | 1 | download1 |
| 125 | Matrix3D.rotY | sub_426BE3 | 1 | 1 | download1 |
| 126 | Matrix3D.rotZ | sub_426C3D | 1 | 1 | download1 |
| 127 | Matrix3D.?127 | sub_426C97 | 1 | 2 | download1 |
| 128 | Matrix3D.?128 | sub_426D7B | 1 | 1 | download1 |
| 132 | Vector3D.sum | sub_42A132 | 1 | 1 | download1 |
| 141 | RayCast.removeSprite | sub_42874B | 1 | 2 | MutantAlert |
| 142 | RayCast.moveSprite | sub_42877A | 1 | 14 | MutantAlert |
| 143 | RayCast.setSpritePos | sub_4287BE | 1 | 7 | MutantAlert |
| 144 | RayCast.setSpriteSize | sub_4288D3 | 1 | 6 | MutantAlert |
| 175 | Runtime.?175 | sub_42B2A0 | 1 | 19 | MidtownMadness3 |
| 177 | Runtime.?177 | sub_42B338 | 1 | 9 | MidtownMadness3 |
| 178 | Catalog.doesGameExist | sub_4240A0 | 1 | 1 | catalog |
| 179 | Catalog.launchGameIfPresent | sub_4240E1 | 1 | 1 | catalog |
| 180 | Catalog.isUserRegistred | sub_424178 | 1 | 2 | Pikubi2 |
| 181 | Catalog.downloadGame | sub_424194 | 1 | 1 | catalog |
| 182 | Catalog.doEditBox | sub_4242B2 | 1 | 1 | catalog |
| 183 | Catalog.atoi | sub_424375 | 1 | 1 | catalog |

== CLEAN GAMES ==
(none)

== NATIVES-ONLY GAMES ==
007Ice-Racer, Arthur&LesPirates, BanjoKazooie, BombJack, BombSquad, catalog, Charmed, Crash Bandicoot, crash_bandicoot, CrazyCobra2, EagleSquadron, FighterPilotEvolved, Flynn, FootballFans, GhostHunter, IFPingPong, IFRacing, IFRacing2, IFSkiExtreme, IFSkiJumping, IFSudoku, JungleRun, MalibuRide2, MonkeyBusiness, Panko, Reversi, SexyBreakerBikini, SexyManga, SexyVideoPoker, ShadoFighter, SouthPark, SphereMadness, SphereMadness2, Spyro, StarWars3, terminator, TheTerminator, TombRaider, TombRaider2, TombRaider3, TourDeFrance, wallbreaker, Worms, XMasTales

counts: total=51 clean=0 natives-only=44 opcodes=7

== SITE CONCENTRATION / TRIAGE OF THE 7 OPCODE GAMES ==
Likely REAL isolated opcodes:
  AgeOfEmpiresMobile — 0x6e×1, single method (class 0x4cdd64a7, method 0xbc1de06c)
  MidtownMadness3    — 0x13, 0xb4, one method (class 0xa163ff43, method 0x305ac842)
  Pikubi2            — 0xc4, 0x25, one method (class 0xfedefd22, method 0x275639e2)
  MutantAlert        — 7 sites across 4 methods
Suspect residual walker desync (confetti of 18-20 distinct bytes confined to 1-4 methods):
  Pikubi    — all 56 sites in 2 methods of class 0xb321a151 (0xd7240d51, 0x0e1ee5ec)
  MotoGp    — 35/46 sites in 2 methods of class 0x77507a33 (0xf53ea4be, 0xf53e2fa0)
  download1 — 60/~69 sites in 4 methods of class 0xe93ddff8
Verify with tools/disasm_method.zig at the first reported pc before porting these.

Porting priority (natives): Sms family (78, 93, 94, 97, 98, 99, 100) clears every
unbound native in 38 of 44 natives-only games. Then: AnimFlash (56/57/60/62/63/64)
→ Spyro, SphereMadness×2, IFRacing2, Worms; RayCast (137/138/141-144) → MutantAlert;
Catalog (178-183) → catalog.exn; unnamed Runtime 175/177 → MidtownMadness3.
