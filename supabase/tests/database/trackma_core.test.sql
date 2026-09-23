begin;

create extension if not exists pgtap with schema extensions;
select plan(40);

insert into auth.users (id, email) values
  ('91000000-0000-0000-0000-000000000001', 'owner@trackma.test'),
  ('91000000-0000-0000-0000-000000000002', 'admin@trackma.test'),
  ('91000000-0000-0000-0000-000000000003', 'lead@trackma.test'),
  ('91000000-0000-0000-0000-000000000004', 'other@trackma.test'),
  ('91000000-0000-0000-0000-000000000005', 'inactive@trackma.test');

insert into public.profiles (id, first_name, last_name) values
  ('91000000-0000-0000-0000-000000000001', 'Olivia', 'Owner'),
  ('91000000-0000-0000-0000-000000000002', 'Adam', 'Admin'),
  ('91000000-0000-0000-0000-000000000003', 'Taylor', 'Lead'),
  ('91000000-0000-0000-0000-000000000004', 'Otto', 'Other'),
  ('91000000-0000-0000-0000-000000000005', 'Ina', 'Inactive');

insert into public.organizations (id, name) values
  ('92000000-0000-0000-0000-000000000001', 'Trackma Tenant A'),
  ('92000000-0000-0000-0000-000000000002', 'Trackma Tenant B');

insert into public.organization_members (id, organization_id, user_id, role, is_active) values
  ('93000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', 'owner', true),
  ('93000000-0000-0000-0000-000000000002', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000002', 'admin', true),
  ('93000000-0000-0000-0000-000000000003', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000003', 'team_lead', true),
  ('93000000-0000-0000-0000-000000000004', '92000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-000000000004', 'owner', true),
  ('93000000-0000-0000-0000-000000000005', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000005', 'agent', true);

insert into public.contract_types (id, organization_id, key, name) values
  ('94000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000001', 'electricity', 'Electricity'),
  ('94000000-0000-0000-0000-000000000002', '92000000-0000-0000-0000-000000000001', 'leasing', 'Leasing'),
  ('94000000-0000-0000-0000-000000000003', '92000000-0000-0000-0000-000000000002', 'electricity', 'Electricity');

insert into public.custom_field_definitions (
  id, organization_id, entity_type, key, label, data_type
) values
  ('95000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000001', 'customer', 'favorite_color', 'Favorite color', 'text'),
  ('95000000-0000-0000-0000-000000000002', '92000000-0000-0000-0000-000000000001', 'contract', 'annual_mileage', 'Annual mileage', 'number'),
  ('95000000-0000-0000-0000-000000000003', '92000000-0000-0000-0000-000000000002', 'customer', 'private_code', 'Private code', 'text');

select has_column('public', 'organizations', 'slug', 'Trackma Core extends existing organizations');

set local role authenticated;
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';

select lives_ok(
  $$insert into public.customers (
      id, organization_id, created_by, owner_id, first_name, last_name
    ) values (
      '96000000-0000-0000-0000-000000000001',
      '92000000-0000-0000-0000-000000000001',
      '91000000-0000-0000-0000-000000000001',
      '91000000-0000-0000-0000-000000000001',
      'Iris', 'Individual'
    )$$,
  'An individual customer can be created through the compatible person path'
);
select results_eq(
  $$select display_name from public.customers where id = '96000000-0000-0000-0000-000000000001'$$,
  array['Iris Individual'::text],
  'Individual display_name is derived without losing person data'
);
select lives_ok(
  $$insert into public.customers (
      id, organization_id, created_by, owner_id, customer_kind, display_name, company_name
    ) values (
      '96000000-0000-0000-0000-000000000002',
      '92000000-0000-0000-0000-000000000001',
      '91000000-0000-0000-0000-000000000001',
      '91000000-0000-0000-0000-000000000001',
      'company', 'Muller GmbH', 'Muller GmbH'
    )$$,
  'A company customer can be created without person names'
);
select lives_ok(
  $$insert into public.contacts (
      id, organization_id, customer_id, first_name, last_name, job_title, is_primary, created_by
    ) values (
      '97000000-0000-0000-0000-000000000001',
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000002',
      'Max', 'Muller', 'Managing Director', true,
      '91000000-0000-0000-0000-000000000001'
    )$$,
  'Company primary contact can be created'
);
select lives_ok(
  $$insert into public.contacts (
      id, organization_id, customer_id, first_name, last_name, job_title, created_by
    ) values (
      '97000000-0000-0000-0000-000000000002',
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000002',
      'Anna', 'Muller', 'Accounting',
      '91000000-0000-0000-0000-000000000001'
    )$$,
  'Company secondary contact can be created'
);
select results_eq(
  $$select count(*) from public.contacts where customer_id = '96000000-0000-0000-0000-000000000002'$$,
  array[2::bigint],
  'A company can have multiple contacts'
);
select lives_ok(
  $$insert into public.contracts (
      id, organization_id, customer_id, created_by, contract_type_id, title, status
    ) values (
      '98000000-0000-0000-0000-000000000001',
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000002',
      '91000000-0000-0000-0000-000000000001',
      '94000000-0000-0000-0000-000000000002',
      'Fleet lease', 'active'
    )$$,
  'A generic non-energy contract can be created'
);
select results_eq(
  $$select count(*) from public.contract_types$$,
  array[2::bigint],
  'Contract types are organization-scoped'
);
select results_eq(
  $$select count(*) from public.contract_types where id = '94000000-0000-0000-0000-000000000003'$$,
  array[0::bigint],
  'A contract type from another organization is invisible'
);
select lives_ok(
  $$insert into public.contracts (
      id, organization_id, customer_id, created_by, contract_type_id, counterparty_name,
      reference_number, signed_at, starts_on, ends_on, status
    ) values (
      '98000000-0000-0000-0000-000000000002',
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000001',
      '91000000-0000-0000-0000-000000000001',
      '94000000-0000-0000-0000-000000000001', 'Example Energy', 'C-123', '2026-01-10', '2026-02-01', '2027-01-31', 'active'
    )$$,
  'Energy uses the generic contract core'
);
select results_eq(
  $$select count(*) from public.contracts
    where id = '98000000-0000-0000-0000-000000000002'
      and contract_type_id = '94000000-0000-0000-0000-000000000001'
      and counterparty_name = 'Example Energy'
      and reference_number = 'C-123'
      and signed_at = '2026-01-10'::date
      and starts_on = '2026-02-01'::date
      and ends_on = '2027-01-31'::date$$,
  array[1::bigint],
  'Generic contract attributes are stored directly'
);
select results_eq(
  $$select count(*) from public.custom_field_definitions$$,
  array[2::bigint],
  'Custom-field definitions are visible only within the active tenant'
);
select results_eq(
  $$select count(*) from public.custom_field_definitions where id = '95000000-0000-0000-0000-000000000003'$$,
  array[0::bigint],
  'A custom-field definition from another organization is invisible'
);
select lives_ok(
  $$insert into public.customer_custom_field_values (
      id, organization_id, customer_id, custom_field_definition_id, data_type, value_text, created_by
    ) values (
      '99000000-0000-0000-0000-000000000001',
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000002',
      '95000000-0000-0000-0000-000000000001',
      'text', 'blue', '91000000-0000-0000-0000-000000000001'
    )$$,
  'A typed customer custom-field value can be created'
);
select lives_ok(
  $$insert into public.contract_custom_field_values (
      id, organization_id, contract_id, custom_field_definition_id, data_type, value_number, created_by
    ) values (
      '99000000-0000-0000-0000-000000000002',
      '92000000-0000-0000-0000-000000000001',
      '98000000-0000-0000-0000-000000000001',
      '95000000-0000-0000-0000-000000000002',
      'number', 20000, '91000000-0000-0000-0000-000000000001'
    )$$,
  'A typed contract custom-field value can be created'
);
select throws_ok(
  $$insert into public.customer_custom_field_values (
      organization_id, customer_id, custom_field_definition_id, data_type, value_number, created_by
    ) values (
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000001',
      '95000000-0000-0000-0000-000000000001',
      'text', 12, '91000000-0000-0000-0000-000000000001'
    )$$,
  '23514', null,
  'A value in the wrong typed column is rejected'
);
select throws_ok(
  $$insert into public.customer_custom_field_values (
      organization_id, customer_id, custom_field_definition_id, data_type,
      value_text, value_number, created_by
    ) values (
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000001',
      '95000000-0000-0000-0000-000000000001',
      'text', 'red', 12, '91000000-0000-0000-0000-000000000001'
    )$$,
  '23514', null,
  'Multiple simultaneously populated value columns are rejected'
);

reset role;

select throws_ok(
  $$insert into public.contacts (
      organization_id, customer_id, first_name, last_name, created_by
    ) values (
      '92000000-0000-0000-0000-000000000002',
      '96000000-0000-0000-0000-000000000002',
      'Cross', 'Tenant', '91000000-0000-0000-0000-000000000004'
    )$$,
  '23503', null,
  'A cross-tenant contact relationship is rejected'
);
select throws_ok(
  $$insert into public.contracts (
      organization_id, customer_id, created_by, contract_type_id, status
    ) values (
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000002',
      '91000000-0000-0000-0000-000000000001',
      '94000000-0000-0000-0000-000000000003', 'active'
    )$$,
  '23503', null,
  'A cross-tenant contract-type relationship is rejected'
);
select throws_ok(
  $$insert into public.customer_custom_field_values (
      organization_id, customer_id, custom_field_definition_id, data_type, value_text, created_by
    ) values (
      '92000000-0000-0000-0000-000000000001',
      '96000000-0000-0000-0000-000000000002',
      '95000000-0000-0000-0000-000000000003',
      'text', 'leak', '91000000-0000-0000-0000-000000000001'
    )$$,
  '23503', null,
  'A cross-tenant customer custom-field definition is rejected'
);
select throws_ok(
  $$insert into public.contract_custom_field_values (
      organization_id, contract_id, custom_field_definition_id, data_type, value_text, created_by
    ) values (
      '92000000-0000-0000-0000-000000000001',
      '98000000-0000-0000-0000-000000000001',
      '95000000-0000-0000-0000-000000000003',
      'text', 'leak', '91000000-0000-0000-0000-000000000001'
    )$$,
  '23503', null,
  'A cross-tenant contract custom-field definition is rejected'
);

insert into public.customers (
  id, organization_id, created_by, owner_id, first_name, last_name
) values
  ('96000000-0000-0000-0000-000000000003', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-000000000002', 'Admin', 'Customer'),
  ('96000000-0000-0000-0000-000000000004', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000003', '91000000-0000-0000-0000-000000000003', 'Lead', 'Customer'),
  ('96000000-0000-0000-0000-000000000005', '92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000005', '91000000-0000-0000-0000-000000000005', 'Inactive', 'Customer'),
  ('96000000-0000-0000-0000-000000000006', '92000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-000000000004', '91000000-0000-0000-0000-000000000004', 'Other', 'Customer');

update public.organization_members set is_active = false where user_id = '91000000-0000-0000-0000-000000000005';
set local role authenticated;
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000002';
select results_eq(
  $$select count(*) from public.customers where id = '96000000-0000-0000-0000-000000000002'$$,
  array[1::bigint],
  'Admin reads other members customers'
);
select results_eq(
  $$select count(*) from public.contacts where customer_id = '96000000-0000-0000-0000-000000000002'$$,
  array[2::bigint],
  'Admin can read company contacts'
);
select results_eq(
  $$select count(*) from public.customer_custom_field_values$$,
  array[1::bigint],
  'Admin can read customer custom-field values'
);
select results_eq(
  $$select count(*) from public.contract_custom_field_values$$,
  array[1::bigint],
  'Admin can read contract custom-field values'
);
select results_eq(
  $$select count(*) from public.customers$$,
  array[5::bigint],
  'Admin sees all organization customers'
);
select lives_ok(
  $$insert into public.contract_types (organization_id, key, name)
    values ('92000000-0000-0000-0000-000000000001', 'service', 'Service')$$,
  'Admin manages contract types'
);
select lives_ok(
  $$insert into public.custom_field_definitions (
      organization_id, entity_type, key, label, data_type
    ) values (
      '92000000-0000-0000-0000-000000000001', 'customer', 'blocked', 'Blocked', 'text'
    )$$,
  'Admin manages custom-field definitions'
);

set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000003';
select results_eq(
  $$select count(*) from public.customers$$,
  array[1::bigint],
  'A team lead still sees only their own customers'
);

set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
select results_eq(
  $$select count(*) from public.customers$$,
  array[5::bigint],
  'Owner receives organization-wide customer access'
);
select results_eq(
  $$select count(*) from public.customers where id = '96000000-0000-0000-0000-000000000006'$$,
  array[0::bigint],
  'A customer in another organization remains invisible'
);

set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000005';
select results_eq(
  $$select count(*) from public.contract_types$$,
  array[0::bigint],
  'An inactive member cannot read contract types'
);
select results_eq(
  $$select count(*) from public.customers$$,
  array[0::bigint],
  'An inactive member cannot read even their assigned customer'
);

reset role;
set local role anon;
set local request.jwt.claim.sub = '';
select throws_ok($$select * from public.contacts$$, '42501', null, 'Anonymous users cannot read contacts');
select throws_ok($$select * from public.contract_types$$, '42501', null, 'Anonymous users cannot read contract types');
select throws_ok($$select * from public.custom_field_definitions$$, '42501', null, 'Anonymous users cannot read custom-field definitions');
select throws_ok($$select * from public.customer_custom_field_values$$, '42501', null, 'Anonymous users cannot read customer custom-field values');
select throws_ok($$select * from public.contract_custom_field_values$$, '42501', null, 'Anonymous users cannot read contract custom-field values');

reset role;
select ok(
  (select bool_and(relrowsecurity)
   from pg_class
   where oid = any (array[
     'public.organizations'::regclass,
     'public.profiles'::regclass,
     'public.organization_members'::regclass,
     'public.customers'::regclass,
     'public.contacts'::regclass,
     'public.contract_types'::regclass,
     'public.contracts'::regclass,
     'public.custom_field_definitions'::regclass,
     'public.customer_custom_field_values'::regclass,
     'public.contract_custom_field_values'::regclass,
     'public.follow_ups'::regclass,
     'public.referrals'::regclass,
     'public.notes'::regclass
   ])),
  'RLS is enabled on every exposed Trackma application table'
);

select * from finish();
rollback;
