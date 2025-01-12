--
-- Setup Users Table
--

create table public.profiles (
  id uuid not null references auth.users on delete cascade,
  nickname text,
  photo_url text,

  primary key (id)
);

alter table public.profiles enable row level security;

-- Allow read access to the user's own profile
create policy "Allow user all access" on public.profiles
  for all using ((select auth.uid()) = id);

-- Allow everyone read access to profiles
create policy "Allow everyone read access" on public.profiles
  for select using (true);

-- inserts a row into public.profiles
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, nickname, photo_url)
  values (new.id, new.raw_user_meta_data ->> 'nickname', new.raw_user_meta_data ->> 'photo_url');
  return new;
end;
$$;

-- trigger the function every time a user is created
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

--
-- Map Projects Table
--

create table
public.smb_map_projects (
    id bigint generated by default as identity primary key,
    uuid uuid null unique, -- This is used as the URL slug
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    published boolean not null default false,
    title text not null default ''::text,
    description text not null default ''::text,
    bounds jsonb null,
    profile_id uuid not null references public.profiles(id) on delete cascade
);

create index on public.smb_map_projects (uuid);
create index on public.smb_map_projects (published);

alter table public.smb_map_projects enable row level security;

alter PUBLICATION supabase_realtime add table public.smb_map_projects;

-- Not authed, only published projects are visible
create policy "Allow public map read access" on public.smb_map_projects
  for select using (published);

-- Authed, only the owner can update or delete
create policy "Allow map owner write access" on public.smb_map_projects
  for all using ((select auth.uid()) = profile_id);

--
-- Drawings Table
--

create table
public.smb_drawings (
	id bigint generated by default as identity primary key,
	created_at timestamp with time zone not null default now(),
	updated_at timestamp with time zone not null default now(),
	shape geometry(LineString, 4326) not null,
	meta text null,
	profile_id uuid not null references public.profiles(id) on delete cascade,
	project_id bigint not null references public.smb_map_projects(id) on delete cascade
);

create index on public.smb_drawings using gist (shape);
alter table public.smb_drawings enable row level security;

-- Allow read access if the drawing's project is published
create policy "Allow published map drawings read access" on public.smb_drawings
  for select using (project_id in (select project_id from public.smb_map_projects where published = true));

-- Authed, only the drawing's owner can update, read, or delete
create policy "Allow drawing owner general access" on public.smb_drawings
  for all using ((select auth.uid()) = profile_id);

--
-- Pins Table
--

create table
public.smb_pins (
	id bigint generated by default as identity primary key,
	created_at timestamp with time zone not null default now(),
	updated_at timestamp with time zone not null default now(),
	shape geometry(Point, 4326) not null,
	meta text null,
	profile_id uuid not null references public.profiles(id) on delete cascade,
	project_id bigint not null references public.smb_map_projects(id) on delete cascade
);

create index on public.smb_pins using gist (shape);
alter table public.smb_pins enable row level security;

-- Allow read access if the pin's project is published
create policy "Allow published map pins read access" on public.smb_pins
  for select using (project_id in (select project_id from public.smb_map_projects where published = true));

-- Authed, only the pin's owner can update, read, or delete
create policy "Allow pin owner general access" on public.smb_pins
  for all using ((select auth.uid()) = profile_id);

--
-- Annotations Table
--

create table
public.smb_annotations (
	id bigint generated by default as identity primary key,
	created_at timestamp with time zone not null default now(),
	updated_at timestamp with time zone not null default now(),
	shape geometry(Point, 4326) not null,
	meta text null,
	profile_id uuid not null references public.profiles(id) on delete cascade,
	project_id bigint not null references public.smb_map_projects(id) on delete cascade
);

create index on public.smb_annotations using gist (shape);
alter table public.smb_annotations enable row level security;

-- Allow read access if the annotation's project is published
create policy "Allow published map annotations read access" on public.smb_annotations
  for select using (project_id in (select project_id from public.smb_map_projects where published = true));

-- Authed, only the annotation's owner can update, read, or delete
create policy "Allow annotation owner general access" on public.smb_annotations
  for all using ((select auth.uid()) = profile_id);

--
-- Attachments Table
--

create table
public.smb_attachments (
	id bigint generated by default as identity primary key,
	created_at timestamp with time zone not null default now(),
	updated_at timestamp with time zone not null default now(),
	shape geometry(Point, 4326) not null,
	meta text null,
	profile_id uuid not null references public.profiles(id) on delete cascade,
	project_id bigint not null references public.smb_map_projects(id) on delete cascade
);

create index on public.smb_attachments using gist (shape);
alter table public.smb_attachments enable row level security;

-- Allow read access if the attachment's project is published
create policy "Allow published map attachments read access" on public.smb_attachments
  for select using (project_id in (select project_id from public.smb_map_projects where published = true));

-- Authed, only the attachment's owner can update, read, or delete
create policy "Allow attachment owner general access" on public.smb_attachments
  for all using ((select auth.uid()) = profile_id);


--
-- Project Bounds Trigger
--

-- Function to update project bounds
CREATE OR REPLACE FUNCTION public.update_project_bounds()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = extensions, public
AS $$
DECLARE
    affected_project_id INTEGER;
    new_bounds JSONB;
BEGIN
    -- Determine the affected_project_id based on the table being updated
    IF TG_OP = 'INSERT' THEN
        affected_project_id := NEW.project_id;
    ELSIF TG_OP = 'DELETE' THEN
        affected_project_id := OLD.project_id;
    ELSE
        RAISE EXCEPTION 'Unexpected operation: %', TG_OP;
    END IF;

    -- Calculate new bounds
    WITH project_shapes AS (
        SELECT
            mp.id AS project_id,
            ST_Collect(ARRAY[
                ST_Collect(d.shape),
                ST_Collect(p.shape),
                ST_Collect(an.shape),
                ST_Collect(at.shape)
            ]) AS combined_shape
        FROM
            public.smb_map_projects mp
        LEFT JOIN
            public.smb_drawings d ON mp.id = d.project_id
        LEFT JOIN
            public.smb_pins p ON mp.id = p.project_id
        LEFT JOIN
            public.smb_annotations an ON mp.id = an.project_id
        LEFT JOIN
            public.smb_attachments at ON mp.id = at.project_id
        WHERE mp.id = affected_project_id
        GROUP BY
            mp.id
    )
    SELECT
        CASE
            WHEN ST_IsEmpty(combined_shape) OR combined_shape IS NULL THEN
                NULL
            ELSE
                json_build_object(
                    'north', ST_YMax(ST_Envelope(combined_shape)),
                    'east', ST_XMax(ST_Envelope(combined_shape)),
                    'south', ST_YMin(ST_Envelope(combined_shape)),
                    'west', ST_XMin(ST_Envelope(combined_shape))
                )
        END INTO new_bounds
    FROM
        project_shapes;

    -- Update the bounds column in the projects table
    UPDATE public.smb_map_projects
    SET bounds = new_bounds
    WHERE id = affected_project_id;

    IF TG_OP = 'INSERT' THEN
        RETURN NEW;
    ELSE
        RETURN OLD;
    END IF;
END;
$$;

-- Create triggers for each annotation table
CREATE TRIGGER update_bounds_on_drawing_change
AFTER INSERT OR DELETE ON public.smb_drawings
FOR EACH ROW EXECUTE FUNCTION public.update_project_bounds();

CREATE TRIGGER update_bounds_on_pin_change
AFTER INSERT OR DELETE ON public.smb_pins
FOR EACH ROW EXECUTE FUNCTION public.update_project_bounds();

CREATE TRIGGER update_bounds_on_annotation_change
AFTER INSERT OR DELETE ON public.smb_annotations
FOR EACH ROW EXECUTE FUNCTION public.update_project_bounds();

CREATE TRIGGER update_bounds_on_attachment_change
AFTER INSERT OR DELETE ON public.smb_attachments
FOR EACH ROW EXECUTE FUNCTION public.update_project_bounds();

--
-- Create avatar bucket
--

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true);


--
-- Avatar bucket policy
--

CREATE POLICY "Give anon users access to avatars bucket" ON storage.objects FOR SELECT TO public USING (bucket_id = 'avatars' AND auth.role() = 'anon');
CREATE POLICY "Give users select access to own folder in avatars bucket" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'avatars' AND (select auth.uid()::text) = (storage.foldername(name))[1]);
CREATE POLICY "Give users insert access to own folder in avatars bucket" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'avatars' AND (select auth.uid()::text) = (storage.foldername(name))[1]);
CREATE POLICY "Give users delete access to own folder in avatars bucket" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'avatars' AND (select auth.uid()::text) = (storage.foldername(name))[1]);
CREATE POLICY "Give users update access to own folder in avatars bucket" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'avatars' AND (select auth.uid()::text) = (storage.foldername(name))[1]);
