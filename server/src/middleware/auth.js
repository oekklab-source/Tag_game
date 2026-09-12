// 認証ミドルウェアのプレースホルダー。
//
// このプロジェクトにはまだユーザー認証機構が存在しない。
// Billing Portal のような「特定顧客のStripeデータへアクセスするAPI」は
// リクエストボディの customerId をそのまま信用すると、
// 任意の顧客の請求情報・支払い方法を第三者が取得できてしまう（IDOR）。
//
// 認証を実装するまでは fail-closed（呼び出しをブロックする）とし、
// 「認証なしで動いているように見えるが実は誰でも他人のデータに触れる」
// という状態を避ける。
//
// 実装時にやること:
//   1. セッション/JWT等でユーザーを認証する処理をここに書く
//   2. req.user にログイン中ユーザーの情報（自社DB上のID等）を積む
//   3. Stripe customerId は req.body から受け取らず、
//      自社DB上の「ユーザーID → Stripe customerId」対応表から引く
function requireAuth(req, res, next) {
  return res.status(501).json({
    error: 'authentication is not implemented yet',
    detail:
      'server/src/middleware/auth.js に認証処理を実装してから、このエンドポイントを有効化してください。',
  });
}

module.exports = { requireAuth };
