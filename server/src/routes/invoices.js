const express = require('express');
const stripe = require('../stripeClient');

const router = express.Router();

// 請求書（Invoicing）を作成しメール送信する
// body: {
//   customerEmail, customerName,
//   items: [{ description, amount, currency }],  // amount は最小単位（例: 円は整数そのまま）
//   daysUntilDue?: number
// }
router.post('/', async (req, res) => {
  try {
    const { customerEmail, customerName, items, daysUntilDue } = req.body;
    if (!customerEmail || !Array.isArray(items) || items.length === 0) {
      return res.status(400).json({ error: 'customerEmail and items are required' });
    }

    const existing = await stripe.customers.list({ email: customerEmail, limit: 1 });
    const customer =
      existing.data[0] ??
      (await stripe.customers.create({ email: customerEmail, name: customerName }));

    for (const item of items) {
      await stripe.invoiceItems.create({
        customer: customer.id,
        amount: item.amount,
        currency: item.currency ?? 'jpy',
        description: item.description,
      });
    }

    const invoice = await stripe.invoices.create({
      customer: customer.id,
      collection_method: 'send_invoice',
      days_until_due: daysUntilDue ?? 14,
      auto_advance: true,
    });

    const finalized = await stripe.invoices.finalizeInvoice(invoice.id);
    await stripe.invoices.sendInvoice(invoice.id);

    res.json({
      id: finalized.id,
      hostedInvoiceUrl: finalized.hosted_invoice_url,
      pdf: finalized.invoice_pdf,
    });
  } catch (err) {
    console.error('invoice creation error:', err.message);
    res.status(500).json({ error: 'failed to create invoice' });
  }
});

module.exports = router;
