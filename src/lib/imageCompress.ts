// Compression client-side avant upload Supabase Storage : redimensionne et ré-encode
// en JPEG en réduisant la qualité jusqu'à atteindre ~200 Ko, sans dépendance externe.
export async function compressImage(file: File, maxDimension = 1600, targetBytes = 200_000): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  const ctx = canvas.getContext('2d')!;
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);

  let quality = 0.85;
  let blob: Blob = await new Promise((resolve) => canvas.toBlob((b) => resolve(b!), 'image/jpeg', quality));

  while (blob.size > targetBytes && quality > 0.3) {
    quality -= 0.1;
    blob = await new Promise((resolve) => canvas.toBlob((b) => resolve(b!), 'image/jpeg', quality));
  }

  return blob;
}
