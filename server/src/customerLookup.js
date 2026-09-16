// 自社ユーザーID → Stripe customerId の対応をここで解決する。
// クライアントから customerId を直接受け取らないための境界。
//
// 実装時にやること: 自社DBに「userId -> stripeCustomerId」を保存し、ここで引く。
async function getStripeCustomerIdForUser(userId) {
  throw new Error(
    'getStripeCustomerIdForUser is not implemented. server/src/customerLookup.js を実装してください。'
  );
}

module.exports = { getStripeCustomerIdForUser };
