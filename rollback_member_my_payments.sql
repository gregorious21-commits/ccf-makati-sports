-- Rollback for member_my_payments.sql. The app then shows the fee only.
drop function if exists public.member_my_payments(text, text);
