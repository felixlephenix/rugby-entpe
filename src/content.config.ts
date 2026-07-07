import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const actus = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/actus' }),
  schema: z.object({
    titre: z.string(),
    date: z.coerce.date(),
    image: z.string().optional(),
    resume: z.string(),
  }),
});

const matchs = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/matchs' }),
  schema: z.object({
    adversaire: z.string(),
    date: z.coerce.date(),
    lieu: z.string(),
    domicile: z.boolean(),
    categorie: z.string(),
    scoreEquipe: z.number().optional(),
    scoreAdversaire: z.number().optional(),
  }),
});

export const collections = { actus, matchs };
