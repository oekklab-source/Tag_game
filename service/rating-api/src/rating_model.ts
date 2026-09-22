/**
 * 非対称 Elo レーティング計算モデル。
 *
 * autoload/ranking_manager.gd (GDScript) の calculate_all_rating_changes() /
 * calculate_rating_delta() / bonus_weight() / tier_index() を1:1移植したもの。
 * 数式の出典・設計意図は docs/RATING_SYSTEM.md を参照。
 *
 * 移植時の唯一の注意点(丸め方式の差異): GDScriptの round() は「0から遠い方向への
 * 四捨五入」(round(-2.5) === -3.0)だが、JS/TSの Math.round() は「+∞方向への丸め」
 * (Math.round(-2.5) === -2)であり、負の.5境界で結果が食い違う。calculate_rating_delta
 * 相当の roundHalfAwayFromZero() で明示的に吸収している(移植ミスの典型的な温床のため、
 * rating_model.test.ts に専用の境界値テストがある)。
 *
 * 計算式そのものに手を加える場合は、GDScript側(autoload/ranking_manager.gd)と
 * docs/RATING_SYSTEM.md の両方に同じ変更を反映すること(3点が常に一致している前提)。
 */

// --- 基本設定定数(autoload/ranking_manager.gd と同じ値) ---
export const K_BASE = 16.0;
export const MAX_TIME = 180.0;
export const BASE_HUNTER_COUNT = 4;
export const HUNTER_COUNT_WEIGHT = 50.0; // 鬼が1人増減するごとの仮想レート補正値
export const TOUCH_TRANSFER_RATIO = 0.3; // 捕獲成功時に協力者からトドメ役に渡す獲得レート比率

// --- レート帯(ティア)定義 ---
// 境界値は下の BONUS_FULL_BELOW / BONUS_ZERO_AT と意図的に一致させている。
export interface Tier {
	id: string;
	name: string;
	min: number;
}

export const TIERS: Tier[] = [
	{ id: "bronze", name: "ブロンズ", min: 0 },
	{ id: "silver", name: "シルバー", min: 1200 },
	{ id: "gold", name: "ゴールド", min: 1400 },
	{ id: "platinum", name: "プラチナ", min: 1600 },
	{ id: "diamond", name: "ダイヤ", min: 1800 },
	{ id: "master", name: "マスター", min: 2000 },
];

// --- 低レート帯ボーナス定義 ---
export const BONUS_FULL_BELOW = 1400.0; // これ以下は満額(シルバー以下)
export const BONUS_ZERO_AT = 1800.0; // これ以上は完全ゼロサム(ダイヤ以上)
export const BONUS_MAX_POINTS = 6.0; // 満額時、Runner 1人が受け取る基準ボーナス
export const BONUS_LOSS_TILT = 0.5; // 負けた側を厚くする係数(連敗で沈むのを防ぐ)

/** レート帯(ティア)のインデックスを返す(0=ブロンズ, 5=マスター) */
export function tierIndex(rating: number): number {
	let idx = 0;
	for (let i = 0; i < TIERS.length; i++) {
		if (rating >= TIERS[i].min) {
			idx = i;
		}
	}
	return idx;
}

export function tierId(rating: number): string {
	return TIERS[tierIndex(rating)].id;
}

export function tierName(rating: number): string {
	return TIERS[tierIndex(rating)].name;
}

/** レートに応じたボーナス係数(1.0 = 満額, 0.0 = ゼロサム)。1400→1800 で線形減衰 */
export function bonusWeight(rating: number): number {
	if (rating >= BONUS_ZERO_AT) {
		return 0.0;
	}
	if (rating <= BONUS_FULL_BELOW) {
		return 1.0;
	}
	return (BONUS_ZERO_AT - rating) / (BONUS_ZERO_AT - BONUS_FULL_BELOW);
}

/**
 * 陣営内の1人あたりのボーナス量。sideScore はその陣営のスコア(0..1)で、
 * 負けた側(スコアが低い側)ほど厚く上乗せする
 */
function bonusFor(rating: number, sideScore: number, teamSize: number): number {
	return (BONUS_MAX_POINTS * bonusWeight(rating) * (1.0 + BONUS_LOSS_TILT * (1.0 - sideScore))) / teamSize;
}

export interface RatingChangeResult {
	runnerDelta: number;
	hunterDeltas: number[];
	bonusRunner: number;
	bonusHunters: number[];
	bonusTotal: number;
}

/**
 * 全員のレートと試合結果を受け取り、全員分のレート変動値を一括計算する。
 * @param runnerRating Runner のレート
 * @param hunterRatings Hunter 全員のレート配列
 * @param survivalTime 生存時間(秒、最大180.0)
 * @param toucherIndex タッチした Hunter のインデックス(未捕獲または CPU の場合は -1)
 * @param applyBonus false にすると低レート帯ボーナスを適用しない従来の厳密ゼロサム計算になる
 */
export function calculateAllRatingChanges(
	runnerRating: number,
	hunterRatings: number[],
	survivalTime: number,
	toucherIndex = -1,
	applyBonus = true,
): RatingChangeResult {
	const n = hunterRatings.length;
	if (n === 0) {
		return { runnerDelta: 0.0, hunterDeltas: [], bonusRunner: 0.0, bonusHunters: [], bonusTotal: 0.0 };
	}

	survivalTime = clamp(survivalTime, 0.0, MAX_TIME);

	// 1. 試合時間によるスコア算出 (0.0 〜 1.0)
	let sr = 1.0;
	if (survivalTime < MAX_TIME) {
		sr = 0.5 * (survivalTime / MAX_TIME);
	}
	const sh = 1.0 - sr;

	// 2. 非対称Kファクターの設定(ゼロサムを担保: K_R = N * K_H)
	const kRunner = K_BASE * Math.sqrt(n);
	const kHunter = K_BASE / Math.sqrt(n);

	// 3. 人数補正(N=4を基準とし、鬼が多いほど鬼の仮想レートが上がる)
	let sumHunterRating = 0.0;
	for (const r of hunterRatings) {
		sumHunterRating += r;
	}
	const avgHunterRating = sumHunterRating / n;
	const nOffset = HUNTER_COUNT_WEIGHT * (n - BASE_HUNTER_COUNT);
	const effectiveHunterTeamRating = avgHunterRating + nOffset;

	// 4. Runner の期待勝率とレート変動
	const er = 1.0 / (1.0 + Math.pow(10.0, (effectiveHunterTeamRating - runnerRating) / 400.0));
	let runnerDelta = kRunner * (sr - er);

	// 5. 各 Hunter のベースレート変動計算
	const hunterDeltas: number[] = [];
	let sumHunterDeltas = 0.0;
	for (let i = 0; i < n; i++) {
		const effectiveHi = hunterRatings[i] + nOffset;
		const eHi = 1.0 / (1.0 + Math.pow(10.0, (runnerRating - effectiveHi) / 400.0));
		const dHi = kHunter * (sh - eHi);
		hunterDeltas.push(dHi);
		sumHunterDeltas += dHi;
	}

	// 6. 完全ゼロサム誤差補正(ロジスティック曲線の非線形性によるインフレ/デフレを完全防止)
	const errorPool = -runnerDelta - sumHunterDeltas;
	const correctionPerHunter = errorPool / n;
	for (let i = 0; i < n; i++) {
		hunterDeltas[i] += correctionPerHunter;
	}

	// 7. トドメの貢献度再分配(捕獲時 ＆ Hunter陣営がプラスの場合のみ)
	if (survivalTime < MAX_TIME && toucherIndex >= 0 && toucherIndex < n) {
		let totalTransfer = 0.0;
		for (let i = 0; i < n; i++) {
			if (i !== toucherIndex && hunterDeltas[i] > 0.0) {
				const transfer = hunterDeltas[i] * TOUCH_TRANSFER_RATIO;
				hunterDeltas[i] -= transfer;
				totalTransfer += transfer;
			}
		}
		hunterDeltas[toucherIndex] += totalTransfer;
	}

	// 8. 低レート帯ボーナス(序盤は純増、上位帯はゼロサムのまま)。
	// ここより前(6のゼロサム誤差補正・7のトドメ再分配)は一切変更しない。
	let bonusRunner = 0.0;
	const bonusHunters: number[] = new Array(n).fill(0.0);
	if (applyBonus) {
		bonusRunner = bonusFor(runnerRating, sr, 1);
		runnerDelta += bonusRunner;
		for (let i = 0; i < n; i++) {
			const bH = bonusFor(hunterRatings[i], sh, n);
			bonusHunters[i] = bH;
			hunterDeltas[i] += bH;
		}
	}
	let bonusTotal = bonusRunner;
	for (const b of bonusHunters) {
		bonusTotal += b;
	}

	return { runnerDelta, hunterDeltas, bonusRunner, bonusHunters, bonusTotal };
}

/**
 * GDScriptの round() (0から遠い方向への四捨五入)相当。
 * JSの Math.round() は +∞方向への丸め(Math.round(-2.5) === -2)なのでそのままでは使えない。
 */
export function roundHalfAwayFromZero(x: number): number {
	return x < 0 ? -Math.round(-x) : Math.round(x);
}

function clamp(x: number, lo: number, hi: number): number {
	return Math.min(Math.max(x, lo), hi);
}

/**
 * 単一プレイヤー向けのレート変動量計算(サーバー側の確定計算用ラッパー)。
 * @param isRunner 自身が Runner だったか
 * @param isWinner 自身が勝利したか
 * @param survivalTime 試合継続時間(秒、最大180.0)
 * @param hunterCount 参加していた Hunter の人数
 * @param isTagger (Hunter の場合) 自身が実際に Runner をタッチしたか
 * @param myRating 自身の現在のレート
 * @param opponentAvgRating 相手陣営の平均レート
 */
export function calculateRatingDelta(
	isRunner: boolean,
	isWinner: boolean,
	survivalTime: number,
	hunterCount: number,
	isTagger = false,
	myRating = 1500,
	opponentAvgRating = 1500,
): number {
	hunterCount = Math.max(1, hunterCount);
	survivalTime = clamp(survivalTime, 0.0, MAX_TIME);

	// 逃げ切り(Runnerが最後まで生き残った試合)は survival_time を必ず満額(MAX_TIME)に正規化する。
	// autoload/ranking_manager.gd の calculate_rating_delta() 同様、Runner視点・Hunter視点の
	// どちらで計算しても同じ sr=1.0 / sh=0.0 になることを担保するため。
	if (isRunner === isWinner) {
		survivalTime = MAX_TIME;
	}

	// 「捕獲されたか」は survival_time では判定しない(逃げ切り時は正規化で常にMAX_TIMEになるため)。
	// is_runner と is_winner の食い違いは正規化の影響を受けない直接の捕獲判定。
	const captured = isRunner !== isWinner;
	const toucherIdx = captured ? 0 : -1;

	if (isRunner) {
		const hunterRatings: number[] = new Array(hunterCount).fill(opponentAvgRating);
		const res = calculateAllRatingChanges(myRating, hunterRatings, survivalTime, toucherIdx);
		return roundHalfAwayFromZero(res.runnerDelta);
	} else {
		const hunterRatings: number[] = new Array(hunterCount).fill(myRating);
		const res = calculateAllRatingChanges(opponentAvgRating, hunterRatings, survivalTime, toucherIdx);
		let targetIdx = isTagger ? 0 : Math.min(1, hunterCount - 1);
		if (targetIdx >= res.hunterDeltas.length) {
			targetIdx = 0;
		}
		return roundHalfAwayFromZero(res.hunterDeltas[targetIdx]);
	}
}
