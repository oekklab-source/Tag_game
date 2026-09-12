require('dotenv').config();
const express = require('express');
const cors = require('cors');

const webhookRouter = require('./routes/webhook');
const checkoutRouter = require('./routes/checkout');
const billingRouter = require('./routes/billing');
const invoicesRouter = require('./routes/invoices');

const app = express();

app.use(cors({ origin: process.env.CLIENT_URL }));

// Webhook は署名検証のため生ボディが必要 → express.json() より前にマウントする
app.use('/api/webhook', webhookRouter);

app.use(express.json());

app.use('/api/checkout', checkoutRouter);
app.use('/api/billing', billingRouter);
app.use('/api/invoices', invoicesRouter);

app.get('/health', (req, res) => res.json({ ok: true }));

const port = process.env.PORT || 4242;
app.listen(port, () => console.log(`stripe server listening on :${port}`));
